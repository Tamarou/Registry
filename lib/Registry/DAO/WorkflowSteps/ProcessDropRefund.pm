# ABOUTME: Refunds an approved enrollment drop, and records 'processed' only once money has moved
# ABOUTME: Partial refund of a shared PaymentIntent: one intent covers every child in the cart
use 5.42.0;
use utf8;
use Object::Pad;

class Registry::DAO::WorkflowSteps::ProcessDropRefund :isa(Registry::DAO::WorkflowStep) {
    use Carp qw(confess);
    use Registry::DAO::Enrollment;
    use Registry::DAO::Payment;

    method process ( $db, $, $run = undef ) {
        $run //= do { my ($w) = $self->workflow($db); $w->latest_run($db) };
        my $data = $run->data;

        unless ( $data->{refund_requested} ) {
            return { refund_processed => 0, message => 'No refund requested' };
        }

        my $enrollment_id = $data->{enrollment_id}
            or confess "enrollment_id is required to process a drop refund";

        my $enrollment =
          Registry::DAO::Enrollment->find( $db, { id => $enrollment_id } )
            or confess "Enrollment $enrollment_id not found";

        # Already paid. The idempotency key below is the backstop for a race;
        # this is the guard for the ordinary case of the workflow being
        # re-driven, or a person pressing approve twice.
        if ( ( $enrollment->refund_status // '' ) eq 'processed' ) {
            return {
                refund_processed    => 1,
                refund_status       => 'processed',
                refund_amount_cents => $enrollment->refund_amount_cents,
                message             => 'Refund already processed',
            };
        }

        # Refused, not defaulted. refund_async falls back to the WHOLE payment
        # when no amount is given, and one PaymentIntent covers every child in
        # the cart -- so defaulting here would refund a sibling's seat along
        # with the dropped one. An approval that never carried an amount is an
        # obligation nobody has quantified, and it stays pending.
        my $cents = $data->{refund_amount_cents} // $enrollment->refund_amount_cents;
        unless ( $cents && $cents > 0 ) {
            return {
                refund_processed => 0,
                refund_status    => $enrollment->refund_status,
                error            => 'no refund amount was approved',
                message          => 'Refund requested with no amount; left pending',
            };
        }

        # The enrollment carries its payment because one intent covers the whole
        # cart; there is no per-child intent to find.
        my $payment_id = $enrollment->payment_id;
        unless ($payment_id) {
            return {
                refund_processed => 0,
                refund_status    => $enrollment->refund_status,
                error            => 'enrollment has no payment to refund',
                message          => 'Nothing to refund against; left pending',
            };
        }

        my $payment = Registry::DAO::Payment->find( $db, { id => $payment_id } )
            or confess "Payment $payment_id not found for enrollment $enrollment_id";

        # An idempotency key is passed deliberately. Without one refund_async
        # refuses outright while capacity debt is outstanding on the payment,
        # and a drop refund is a separate obligation -- possibly to a different
        # parent -- that should not wait on it. _apply_refund_result re-checks
        # the debt before moving any status, so the increments stay findable.
        return $payment->refund_async( $db, {
            amount_cents    => $cents,
            reason          => 'requested_by_customer',
            idempotency_key => $payment->drop_refund_key($enrollment_id),
        } )->then(
            sub ($refund) {
                # Only now. 'processed' is the parent's receipt, and writing it
                # before the money moved is the defect this step existed as a
                # TODO for.
                $enrollment->update( $db, { refund_status => 'processed' } );

                return {
                    refund_processed    => 1,
                    refund_status       => 'processed',
                    refund_amount_cents => $cents,
                    refund_id           => ref $refund eq 'HASH' ? $refund->{id} : undef,
                    message             => 'Refund processed',
                };
            },
            # Two-argument then, not a trailing ->catch. A ->catch would also
            # swallow anything the success branch threw and report it as a
            # failed refund -- telling an operator no money moved when it did.
            # If recording fails after Stripe paid, this chain rejects and the
            # step is loud, which is the only honest outcome.
            sub ($error) {
                my $message = "$error";
                $message =~ s/\s+\z//;

                # Left pending on purpose: the money is still owed. Writing a
                # terminal status here would close the obligation in the ledger
                # without closing it at the bank.
                return {
                    refund_processed => 0,
                    refund_status    => $enrollment->refund_status,
                    error            => $message,
                    message          => 'Refund failed; still owed',
                };
            },
        );
    }
}
