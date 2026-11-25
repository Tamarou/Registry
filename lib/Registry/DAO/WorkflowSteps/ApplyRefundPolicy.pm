# ABOUTME: entitlement-refund step: decides a refund request by the refund policy stamped on the entitlement's offer version.
# ABOUTME: Never ends the entitlement: Stripe's report of the refund does, through entitlement-stripe-move.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::ApplyRefundPolicy :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Entitlement;

    # Why $entitlement gets no refund under the refund policy it was sold
    # under (its stamped version, never the current one), or nothing.
    sub refusal ( $class, $db, $entitlement ) {
        my $policy = $entitlement->offer_version($db)->policies->{refund} // {};
        return "This booking's offer says all sales are final: it gives no refunds"
            if ( $policy->{kind} // '' ) eq 'none';
        return;
    }

    # The run names the entitlement (refund_entitlement_id).
    method process ( $db, $form_data, $run = undef ) {
        $db = $db->db if $db isa Registry::DAO;
        my $id = $run ? $run->data->{refund_entitlement_id} : undef;
        my $entitlement = defined $id && !ref $id && Registry::DAO::Entitlement->find( $db, { id => $id } );
        return { stay => 1, errors => ['Choose a booking to refund'] } unless $entitlement;

        if ( my $refusal = __PACKAGE__->refusal( $db, $entitlement ) ) {
            return { refund_refused => $refusal };
        }
        return {};
    }
}

1;
