# ABOUTME: entitlement-change step: charges the change fee the hold step owes, as a one-time payment.
# ABOUTME: Re-checks the person may change the booking before any charge; a zero fee owes nothing and is passed through.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::PayChangeFee :isa(Registry::DAO::WorkflowSteps::OneTimePayment) {
    use Registry::DAO::Entitlement;
    use Registry::Terms ();
    use Registry::DAO::WorkflowSteps::ChooseChangeTarget;

    method process ( $db, $form_data, $run = undef ) {
        $db = $db->db if $db isa Registry::DAO;
        # Before the checks below, so a return after the driver moved on is sent on.
        if ( my $moved = $self->moved_on( $db, $run ) ) { return $moved }
        my $change = $run->data->{change_hold};
        my $entitlement = ref $change eq 'HASH' && !ref $change->{entitlement_id}
            && Registry::DAO::Entitlement->find( $db, { id => $change->{entitlement_id} } );
        return { stay => 1, errors => ['Choose an occurrence to change to'] } unless $entitlement;
        my $user = $run->data->{user};
        if ( my $refusal = Registry::DAO::WorkflowSteps::ChooseChangeTarget->stranger( $entitlement, $user ) ) {
            return { stay => 1, errors => [$refusal] };
        }
        return {} unless $change->{fee_cents};
        if ( my $refusal = Registry::Terms::checkout_refusal() ) {
            return $self->_stay( errors => [$refusal] );
        }
        # Whoever pays the fee is the one paying now: the holder, or an admin for them.
        $run->update_data( $db, { user_id => $user->{id} } );
        return $self->SUPER::process( $db, $form_data, $run );
    }

    # Nothing to ask on a zero fee, so the controller passes this step through.
    method nothing_to_ask ( $db, $run ) {
        my $change = $run->data->{change_hold};
        return ref $change eq 'HASH' && !$change->{fee_cents};
    }
}

1;
