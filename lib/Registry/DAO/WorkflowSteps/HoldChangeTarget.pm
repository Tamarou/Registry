# ABOUTME: entitlement-change step: re-checks the change and holds the target's seats for the run before any charge.
# ABOUTME: Writes the run's change, with the hold, from the stamped policy and the placed hold only, never the form.
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
        my $choose = 'Registry::DAO::WorkflowSteps::ChooseChangeTarget';
        my $tx     = $db->dbh->{AutoCommit} ? $db->begin : undef;
        # One change hold per run: a second submit waits on the run's row,
        # then gives back the first one's hold before taking its own. Every
        # refusal below returns before $tx commits, so nothing is left behind.
        my $data = $db->query( 'SELECT data FROM workflow_runs WHERE id = ? FOR UPDATE', $run->id )
            ->expand->hash->{data} // {};
        my $entitlement_id = $data->{change_entitlement_id};
        my $entitlement    = $entitlement_id && Registry::DAO::Entitlement->find( $db, { id => $entitlement_id } );
        return { stay => 1, errors => ['Choose a booking to change'] } unless $entitlement;
        # The window may have closed while the page was open.
        if ( my $refusal = $choose->refusal( $db, $entitlement ) ) {
            return { stay => 1, errors => [$refusal] };
        }
        my $live = Registry::PriceOps::Hold->live_sql('holds');
        $db->query( "UPDATE holds SET state = 'released' WHERE workflow_run_id = ? AND $live", $run->id );

        my $target_id = $form_data->{target_occurrence_id};
        my ($target) = grep { $_->id eq ( $target_id // '' ) } $choose->targets( $db, $entitlement )->@*;
        return { stay => 1, errors => ['Choose one of the listed occurrences'] } unless $target;

        my $version = $entitlement->offer_version($db);
        my $minutes = $self->metadata->{hold_minutes} // $HOLD_MINUTES;
        my $seats   = $choose->seats( $db, $entitlement );
        # The listing read the target's room unlocked; place re-checks it under
        # the target's lock, and another hold may have taken it meanwhile.
        my $hold = eval {
            Registry::PriceOps::Hold->place( $db, {
                resource_id     => $target->id,
                units           => $seats,
                workflow_run_id => $run->id,
                expires_at      => \[ "clock_timestamp() + make_interval(mins => ?)", $minutes ],
            } );
        };
        unless ($hold) {
            die $@ unless $@ =~ /units free/;
            return { stay => 1, errors => ["That occurrence no longer has room for $seats"] };
        }
        # Written with the hold, under the run's lock: written after commit, an
        # earlier submit's change could land over a later one's.
        $run->update_data( $db, { change => {
            entitlement_id       => $entitlement->id,
            target_occurrence_id => $target->id,
            hold_id              => $hold->id,
            fee_cents            => $version->policies->{change}{fee_cents},
            offer_version_id     => $version->id,
        } } );
        $tx->commit if $tx;
        return {};
    }
}

1;
