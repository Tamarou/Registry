# ABOUTME: platform-fee-refund-exception step: sends the recorded fee-refund request to Stripe under its idempotency key.
# ABOUTME: Safe to press again: a fee already returned finishes the run and nothing more is sent.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::ApplyFeeRefundException :isa(Registry::DAO::WorkflowStep) {
    use Mojo::Promise;
    use Registry::DAO::Payment;
    use Registry::DAO::WorkflowSteps::FindTenantPayment;

    method process ( $db, $form_data, $run = undef ) {
        my $found = Registry::DAO::WorkflowSteps::FindTenantPayment->located( $db, $form_data, $run, returned_ok => 1 );
        return { stay => 1, errors => [ $found->{error} ] } if $found->{error};

        my $payment = $found->{payment};
        my $request = ( $payment->metadata // {} )->{platform_fee_refund_exception};
        return { stay => 1, errors => ['No fee-refund exception is recorded on that payment'] }
            unless ref $request eq 'HASH';
        # Stripe reported it returned (an earlier press, or by hand): done.
        return { fee_refund => { already_returned_cents => $payment->platform_fee_refunded_cents } }
            unless $found->{remaining_cents} > 0;

        # From a resolved promise, so a guard's REFUND_NOT_SENT is a rejection
        # the failure branch reports rather than a 500.
        my $tdb = $found->{tenant}->dao->db;
        return Mojo::Promise->resolve->then( sub {
            $payment->refund_platform_fee_async( $tdb, {
                amount_cents    => $request->{amount_cents},
                idempotency_key => $request->{idempotency_key},
            } );
        } )->then(
            sub ($fee_refund) {
                return { fee_refund => defined $fee_refund->{already_returned_cents}
                    ? { already_returned_cents => $fee_refund->{already_returned_cents} }
                    : { id => $fee_refund->{id}, amount_cents => $fee_refund->{amount} } };
            },
            sub ($error) {
                my $message = "$error" =~ s/\s+\z//r;
                my $sent    = Registry::DAO::Payment->classify_refund_failure($error) eq 'not_sent'
                    ? 'Nothing was sent to Stripe' : 'Stripe may or may not have it; pressing again is safe';
                return { stay => 1, errors => ["Fee refund not completed ($sent): $message"] };
            },
        );
    }
}

1;
