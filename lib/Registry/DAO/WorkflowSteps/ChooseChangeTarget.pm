# ABOUTME: entitlement-change step: checks a change against the entitlement's stamped policy and lists its targets.
# ABOUTME: Targets are the other occurrences its sold-under offer version covers that are still to start and have room.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::ChooseChangeTarget :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Entitlement;
    use Registry::DAO::Resource;

    method process ( $db, $form_data, $run = undef ) {
        my $id = $form_data->{entitlement_id};
        my $entitlement = defined $id && !ref $id && Registry::DAO::Entitlement->find( $db, { id => $id } );
        return { stay => 1, errors => ['Choose a booking to change'] } unless $entitlement;
        if ( my $refusal = __PACKAGE__->refusal( $db, $entitlement ) ) {
            return { stay => 1, errors => [$refusal] };
        }
        return {
            change_entitlement_id => $entitlement->id,
            change_targets        => [ map { { id => $_->id, name => $_->name } }
                __PACKAGE__->targets( $db, $entitlement )->@* ],
        };
    }

    # Why $entitlement may not change now under the change policy it was sold
    # under (its stamped version, never the current one), or nothing. The
    # boundary is inclusive (ADR 005 8b): exactly window_hours before its
    # occurrence starts, a change is still allowed.
    sub refusal ( $class, $db, $entitlement ) {
        my $policy = $entitlement->offer_version($db)->policies->{change} // {};
        return "This booking's offer says it cannot be changed" unless ( $policy->{kind} // '' ) eq 'window';
        my ($resource_id) = $db->select( 'entitlement_units', 'resource_id',
            { entitlement_id => $entitlement->id } )->arrays->flatten->each;
        my ($starts) = Registry::DAO::Resource->find( $db, { id => $resource_id } )->occurrence_window($db);
        return sprintf 'Changes close %d hours before the class starts', $policy->{window_hours}
            unless $db->query( 'SELECT clock_timestamp() <= ?::timestamptz - make_interval(hours => ?)',
                $starts, $policy->{window_hours} )->array->[0];
        return;
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
