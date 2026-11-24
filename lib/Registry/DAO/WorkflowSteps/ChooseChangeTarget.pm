# ABOUTME: entitlement-change step: checks a change against the entitlement's stamped policy and lists its targets.
# ABOUTME: Targets are the other occurrences its sold-under offer version covers that are still to start and have room.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::ChooseChangeTarget :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Entitlement;

    method process ( $db, $form_data, $run = undef ) {
        my $id = $form_data->{entitlement_id};
        my $entitlement = defined $id && !ref $id && Registry::DAO::Entitlement->find( $db, { id => $id } );
        return { stay => 1, errors => ['Choose a booking to change'] } unless $entitlement;
        return {
            change_entitlement_id => $entitlement->id,
            change_targets        => [ map { { id => $_->id, name => $_->name } }
                __PACKAGE__->targets( $db, $entitlement )->@* ],
        };
    }

    # The occurrences $entitlement may move to now: its change targets that
    # are still to start and have room for every seat it holds.
    sub targets ( $class, $db, $entitlement ) {
        my $seats = $class->seats( $db, $entitlement );
        return [ grep { $class->is_to_start( $db, $_ ) && $_->free_units($db) >= $seats }
                $entitlement->change_targets($db)->@* ];
    }

    sub seats ( $class, $db, $entitlement ) {
        return $db->select( 'entitlement_units', 'count(*)', { entitlement_id => $entitlement->id } )
            ->array->[0];
    }

    # Whether occurrence-resource $resource starts after the clock.
    sub is_to_start ( $class, $db, $resource ) {
        my ($starts) = $resource->occurrence_window($db);
        return $db->query( 'SELECT clock_timestamp() < ?::timestamptz', $starts )->array->[0];
    }
}

1;
