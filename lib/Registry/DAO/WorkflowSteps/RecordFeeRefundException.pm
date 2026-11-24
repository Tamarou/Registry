# ABOUTME: platform-fee-refund-exception step: records, once per payment, the admin's reason and the fee to return.
# ABOUTME: The record carries the payment-derived idempotency key the apply step sends to Stripe.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::RecordFeeRefundException :isa(Registry::DAO::WorkflowStep) {
    use Mojo::JSON qw( encode_json );
    use Registry::DAO::WorkflowSteps::FindTenantPayment;

    method process ( $db, $form_data, $run = undef ) {
        my $found = Registry::DAO::WorkflowSteps::FindTenantPayment->located( $db, $form_data, $run );
        return { stay => 1, errors => [ $found->{error} ] } if $found->{error};

        my $payment = $found->{payment};
        # Written only when absent, in one statement: a second application,
        # or two at once, leaves the first request as it was.
        $found->{tenant}->dao->db->query( q{
            UPDATE payments
               SET metadata = COALESCE(metadata, '{}'::jsonb)
                   || jsonb_build_object('platform_fee_refund_exception', ?::jsonb || jsonb_build_object('requested_at', now()))
             WHERE id = ? AND metadata->'platform_fee_refund_exception' IS NULL
        }, encode_json( {
            idempotency_key           => 'platform-fee-refund:' . $payment->id,
            reason                    => $form_data->{reason},
            amount_cents              => $found->{remaining_cents},
            platform_offer_version_id => $found->{terms}{id},
            requested_by              => $form_data->{user_id},
        } ), $payment->id );

        return { fee_refund_recorded => 1 };
    }
}

1;
