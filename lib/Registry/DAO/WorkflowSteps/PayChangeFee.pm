# ABOUTME: entitlement-change step: charges the change fee the hold step owes, as a one-time payment.
# ABOUTME: Re-checks the person may change the booking before any charge; a zero fee owes nothing and is passed through.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::PayChangeFee :isa(Registry::DAO::WorkflowSteps::OneTimePayment) {
    use Registry::DAO::Entitlement;
    use Registry::DAO::WorkflowSteps::ChooseChangeTarget;

    method process ( $db, $form_data, $run = undef ) {
        $db = $db->db if $db isa Registry::DAO;
        # The person's return from Stripe can land after the driver moved the
        # run on; processing this step again would wind it back, so they are
        # sent to where the run is.
        my $at = $run->next_step($db) // $run->latest_step($db);
        return { redirect => join '/', '', $self->workflow($db)->slug, $run->id, $at->slug }
            if $at->id ne $self->id;
        my $change = $run->data->{change_hold};
        my $entitlement = ref $change eq 'HASH' && !ref $change->{entitlement_id}
            && Registry::DAO::Entitlement->find( $db, { id => $change->{entitlement_id} } );
        return { stay => 1, errors => ['Choose an occurrence to change to'] } unless $entitlement;
        my $user = $run->data->{user};
        if ( my $refusal = Registry::DAO::WorkflowSteps::ChooseChangeTarget->stranger( $entitlement, $user ) ) {
            return { stay => 1, errors => [$refusal] };
        }
        return {} unless $change->{fee_cents};
        # Whoever pays the fee is the one paying now: the holder, or an admin for them.
        $run->update_data( $db, { user_id => $user->{id} } );
        return $self->SUPER::process( $db, $form_data, $run );
    }

    # Nothing to ask on a zero fee, so the controller passes this step through.
    method nothing_to_ask ( $db, $run ) {
        my $change = $run->data->{change_hold};
        return ref $change eq 'HASH' && !$change->{fee_cents};
    }

    # Stripe's return leg arrives as a GET carrying payment_intent; the
    # controller hands it to process only for a step that has this.
    method handle_payment_callback ( $db, $run, $form_data ) { $self->process( $db, $form_data, $run ) }
}

1;
