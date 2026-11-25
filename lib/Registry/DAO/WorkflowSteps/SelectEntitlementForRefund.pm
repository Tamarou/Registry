# ABOUTME: entitlement-refund step: the person picks one of their bookings that is in effect to ask a refund of.
# ABOUTME: Writes the server-owned refund_entitlement_id only once the booking is theirs (or they are admin or staff).
use 5.42.0;
use utf8;

use Object::Pad;

# The change chooser's listing (the person's bookings in effect) and its
# ownership check (stranger) are this step's too.
class Registry::DAO::WorkflowSteps::SelectEntitlementForRefund :isa(Registry::DAO::WorkflowSteps::ChooseChangeTarget) {
    use Registry::DAO::Entitlement;

    method process ( $db, $form_data, $run = undef ) {
        my $id = $form_data->{entitlement_id};
        my $entitlement = defined $id && !ref $id && Registry::DAO::Entitlement->find( $db, { id => $id } );
        return { stay => 1, errors => ['Choose a booking to refund'] } unless $entitlement;
        if ( my $refusal = __PACKAGE__->stranger( $entitlement,
                $run && $run->data->{user}, 'refund' ) ) {
            return { stay => 1, errors => [$refusal] };
        }
        return { stay => 1, errors => ['This booking has ended and cannot be refunded'] }
            unless $entitlement->state eq 'active';
        return { refund_entitlement_id => $entitlement->id };
    }
}

1;
