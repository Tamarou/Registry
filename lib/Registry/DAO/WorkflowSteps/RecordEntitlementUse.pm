# ABOUTME: Staff day step: marking someone present records one use of the entitlement they hold for the occurrence.
# ABOUTME: Use is optional attendance: recording it changes no state, units, expiry or money, and a repeat overwrites the earlier mark.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::RecordEntitlementUse :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Entitlement;

    my $UUID = qr/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i;

    # $form_data names entitlement_id and occurrence_id; user_id, the acting
    # staff member, is what the workflow controller puts there.
    method process ( $db, $form_data, $run = undef ) {
        my ( $entitlement_id, $occurrence_id ) = $form_data->@{qw( entitlement_id occurrence_id )};
        return { stay => 1, errors => ['Choose a booking and an occurrence to mark'] }
            unless 2 == grep { defined && !ref && /$UUID/ } $entitlement_id, $occurrence_id;
        my $entitlement = Registry::DAO::Entitlement->find( $db, { id => $entitlement_id } );
        return { stay => 1, errors => ['That booking was not found'] } unless $entitlement;
        eval { $entitlement->record_use( $db, $occurrence_id, $form_data->{user_id} ); 1 } and return {};
        die $@ unless $@ isa Registry::DAO::Entitlement::Refused;
        return { stay => 1, errors => [ $@->message =~ s/\n\z//r ] };
    }
}

1;
