# ABOUTME: entitlement-change step: re-checks the change and holds the target's seats for the run before any charge.
# ABOUTME: Writes the run's change from the stamped policy and the placed hold only, never from the form.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::HoldChangeTarget :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Entitlement;
    use Registry::DAO::WorkflowSteps::ChooseChangeTarget;
    use Registry::PriceOps::Hold;

    # Long enough to pay the fee; the step's metadata may say otherwise.
    my $HOLD_MINUTES = 15;

    method process ( $db, $form_data, $run = undef ) {
        my $choose      = 'Registry::DAO::WorkflowSteps::ChooseChangeTarget';
        my $entitlement_id = $run->data->{change_entitlement_id};
        my $entitlement    = $entitlement_id && Registry::DAO::Entitlement->find( $db, { id => $entitlement_id } );
        return { stay => 1, errors => ['Choose a booking to change'] } unless $entitlement;
        # The window may have closed while the page was open.
        if ( my $refusal = $choose->refusal( $db, $entitlement ) ) {
            return { stay => 1, errors => [$refusal] };
        }
        my $target_id   = $form_data->{target_occurrence_id};
        my ($target) = grep { $_->id eq ( $target_id // '' ) } $choose->targets( $db, $entitlement )->@*;
        return { stay => 1, errors => ['Choose one of the listed occurrences'] } unless $target;

        my $version = $entitlement->offer_version($db);
        my $minutes = $self->metadata->{hold_minutes} // $HOLD_MINUTES;
        my $hold    = Registry::PriceOps::Hold->place( $db, {
            resource_id     => $target->id,
            units           => $choose->seats( $db, $entitlement ),
            workflow_run_id => $run->id,
            expires_at      => \[ "clock_timestamp() + make_interval(mins => ?)", $minutes ],
        } );
        return { change => {
            entitlement_id       => $entitlement->id,
            target_occurrence_id => $target->id,
            hold_id              => $hold->id,
            fee_cents            => $version->policies->{change}{fee_cents},
            offer_version_id     => $version->id,
        } };
    }
}

1;
