# ABOUTME: entitlement-refund step: decides a refund request by the refund policy stamped on the entitlement's offer version.
# ABOUTME: Never ends the entitlement: Stripe's report of the refund does, through entitlement-stripe-move.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::ApplyRefundPolicy :isa(Registry::DAO::WorkflowStep) {
    use Mojo::JSON qw( encode_json );
    use Mojo::Promise;
    use Registry::DAO::Entitlement;
    use Registry::DAO::Payment;
    use Registry::DAO::WorkflowSteps::ChooseChangeTarget;

    # Why $entitlement gets no refund at $at (default the clock) under the
    # refund policy it was sold under (its stamped version, never the current
    # one), or nothing. The cutoff is inclusive (ADR 005 8b): asked at exactly
    # the cutoff, the refund is still given.
    sub refusal ( $class, $db, $entitlement, $at = undef ) {
        $db = $db->db if $db isa Registry::DAO;
        return 'This booking has ended and cannot be refunded' unless $entitlement->state eq 'active';
        my $policy = $entitlement->offer_version($db)->policies->{refund} // {};
        my $kind   = $policy->{kind} // '';
        return "This booking's offer says all sales are final: it gives no refunds" if $kind eq 'none';
        return "This booking's offer keeps the platform fee on a refund: ask the studio's admin, "
            . 'who can return it through the fee-refund exception'
            if $kind eq 'keep_fee_with_admin_exception';
        # Anything else is refused, never read as a full refund.
        return "This booking's offer has no refund policy this step applies ($kind): nothing is refunded"
            unless $kind eq 'full_until_cutoff' && ( defined $policy->{cutoff_at} xor defined $policy->{cutoff_hours} );
        return 'This booking was not paid for, so there is nothing to refund'
            unless $entitlement->payment_id && $entitlement->payment_share_cents;
        return 'This booking has already been refunded in full' unless $class->remaining_cents( $db, $entitlement ) > 0;

        my ( $cutoff, $until ) = defined $policy->{cutoff_at}
            ? ( $policy->{cutoff_at}, $policy->{cutoff_at} )
            : ( $db->query( 'SELECT min(s) - make_interval(hours => ?) FROM unnest(?::timestamptz[]) s',
                  $policy->{cutoff_hours}, [ map { $_->[0] } $entitlement->occurrence_windows($db)->@* ] )->array->[0],
                "$policy->{cutoff_hours} hours before it starts" );
        return "This booking's offer gives a full refund only until $until, which has passed"
            unless $db->query( 'SELECT coalesce(?::timestamptz, clock_timestamp()) <= ?::timestamptz', $at, $cutoff )
                ->array->[0];
        return;
    }

    # Its share of its payment less what has been refunded against it.
    sub remaining_cents ( $class, $db, $entitlement ) {
        return $entitlement->payment_share_cents - $entitlement->refunded_cents($db);
    }

    # Records on its payment the refund to ask Stripe for: what is left of
    # this entitlement's share, under a key derived from the entitlement, so a
    # retry or a double submit is one refund. Returns { payment, amount_cents,
    # idempotency_key }.
    sub request ( $class, $db, $entitlement ) {
        $db = $db->db if $db isa Registry::DAO;
        my %request = (
            amount_cents    => $class->remaining_cents( $db, $entitlement ),
            idempotency_key => 'refund:entitlement:' . $entitlement->id,
        );
        $db->query( q{
            UPDATE payments
               SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('entitlement_refund_requests',
                       COALESCE(metadata->'entitlement_refund_requests', '{}'::jsonb) || jsonb_build_object(?::text, ?::jsonb))
             WHERE id = ?
        }, $entitlement->id, encode_json( \%request ), $entitlement->payment_id );
        return { %request, payment => $entitlement->payment($db) };
    }

    # The refund terms its page shows: the offer's name and its stamped refund
    # policy, in the offer's words.
    method prepare_template_data ( $db, $run, $params = {} ) {
        $db = $db->db if $db isa Registry::DAO;
        my $id = $run->data->{refund_entitlement_id};
        my $entitlement = defined $id && !ref $id && Registry::DAO::Entitlement->find( $db, { id => $id } )
            or return {};
        my $version = $entitlement->offer_version($db);
        return {
            offer_name => $db->select( 'offers', 'name', { id => $version->offer_id } )->array->[0],
            refund     => $version->policies->{refund} // {},
        };
    }

    # The run names the entitlement (refund_entitlement_id).
    method process ( $db, $form_data, $run = undef ) {
        $db = $db->db if $db isa Registry::DAO;
        my $id = $run ? $run->data->{refund_entitlement_id} : undef;
        my $entitlement = defined $id && !ref $id && Registry::DAO::Entitlement->find( $db, { id => $id } );
        return { stay => 1, errors => ['Choose a booking to refund'] } unless $entitlement;
        # Asked again here: another person posting to this run's URL gets no further.
        if ( my $stranger = Registry::DAO::WorkflowSteps::ChooseChangeTarget->stranger( $entitlement,
                $run->data->{user}, 'refund' ) ) {
            return { stay => 1, errors => [$stranger] };
        }

        if ( my $refusal = __PACKAGE__->refusal( $db, $entitlement ) ) {
            return { refund_refused => $refusal };
        }

        my $request = __PACKAGE__->request( $db, $entitlement );
        my $payment = $request->{payment};
        # From a resolved promise, so a guard's REFUND_NOT_SENT is a rejection
        # the failure branch reports rather than a 500.
        return Mojo::Promise->resolve->then( sub {
            $payment->refund_async( $db, {
                amount_cents    => $request->{amount_cents},
                reason          => 'requested_by_customer',
                idempotency_key => $request->{idempotency_key},
            } );
        } )->then(
            sub ($refund) {
                return { refund_requested => {
                    entitlement_id => $entitlement->id,
                    amount_cents   => $request->{amount_cents},
                    refund_id      => $refund->{id},
                    status         => $refund->{status},
                } };
            },
            sub ($error) {
                $payment->record_refund_failure( $db, $error );
                my $message = "$error" =~ s/\s+\z//r;
                my $sent    = Registry::DAO::Payment->classify_refund_failure($error) eq 'not_sent'
                    ? 'Nothing was sent to Stripe' : 'Stripe may or may not have it; asking again is safe';
                return { stay => 1, errors => ["Refund not requested ($sent): $message"] };
            },
        );
    }
}

1;
