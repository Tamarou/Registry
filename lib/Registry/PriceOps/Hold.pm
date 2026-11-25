# ABOUTME: A time-limited hold on N units of a finite resource, for the workflow run that placed it.
# ABOUTME: Live while held and before expires_at; placed under the resource lock, so it never overruns capacity.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::PriceOps::Hold :isa(Registry::DAO::Object) {
    use Registry::DAO::Resource;
    use Registry::DAO::Entitlement;
    use Carp qw( croak );

    field $id :param :reader;
    field $resource_id :param :reader;
    field $units :param :reader;
    field $workflow_run_id :param :reader;
    field $expires_at :param :reader;
    field $state :param :reader;    # held, converted or released

    sub table { 'holds' }

    # Holds $data->{units} units of $data->{resource_id} for
    # $data->{workflow_run_id} until $data->{expires_at}, which must be later
    # than now: a zero or past lifetime is refused.
    sub place ( $class, $db, $data ) {
        $db = $db->db if $db isa Registry::DAO;
        my $tx       = $db->dbh->{AutoCommit} ? $db->begin : undef;
        my $resource = Registry::DAO::Resource->locked( $db, $data->{resource_id} );
        $resource->claim( $db, $data->{units} );
        my $hold = $class->create( $db, $data );
        croak 'a hold must expire after it is placed'
            unless $db->query( 'SELECT ?::timestamptz > clock_timestamp()', $hold->expires_at )->array->[0];
        # The lifetime it was placed with bounds any extension (OneTimePayment).
        $db->query( 'UPDATE holds SET lifetime = expires_at - placed_at WHERE id = ?', $hold->id );
        $tx->commit if $tx;
        return $hold;
    }

    # The one liveness rule, as SQL over hold row $h: held, and the clock has
    # not passed expires_at (inclusive, ADR 005 8b). The clock, not now(), so a
    # request that waited on the resource lock sees holds that lapsed meanwhile.
    sub live_sql ( $class, $h ) {
        return "($h.state = 'held' AND clock_timestamp() <= $h.expires_at)";
    }

    # Turns this live hold into an entitlement's units, once: given entitlement
    # fields ($into, as Entitlement->grant takes them, payment link included),
    # grants a new entitlement holding the hold's units. Given an existing
    # Entitlement, moves it onto the hold's units in place instead: it keeps
    # its id, state and payment link, and gives up the units it held. A move
    # is refused, leaving the hold held, unless the entitlement is active and
    # not yet over, buys the hold's resource and holds as many units as it.
    method convert ( $db, $into ) {
        $db = $db->db if $db isa Registry::DAO;
        my $tx     = $db->dbh->{AutoCommit} ? $db->begin : undef;
        my $moving = $into isa Registry::DAO::Entitlement;
        my ( $entitlement, @from );
        if ($moving) {
            # Locked before its units are read, so a concurrent move or end waits;
            # every refusal comes before the hold is touched.
            my $current = Registry::DAO::Entitlement->in_effect_sql( 'e', 'tstzrange(now(), NULL)' );
            $current = $db->query( "SELECT $current FROM entitlements e WHERE e.id = ? FOR UPDATE", $into->id )
                ->array->[0];
            $entitlement = Registry::DAO::Entitlement->find( $db, { id => $into->id } );
            croak sprintf 'entitlement %s is %s: units move only onto an active one', $into->id, $entitlement->state
                unless $entitlement->state eq 'active';
            croak sprintf 'entitlement %s has ended: units move only onto a current one', $into->id
                unless $current;
            croak sprintf 'entitlement %s does not buy resource %s', $into->id, $resource_id
                unless $entitlement->offer_version($db)->buys( $db, $resource_id );
            my $has = $db->select( 'entitlement_units', 'count(*)', { entitlement_id => $into->id } )->array->[0];
            croak sprintf 'hold %s is %d units but entitlement %s holds %d: a move keeps its unit count',
                $id, $units, $into->id, $has
                unless $has == $units;
            @from = $db->select( 'entitlement_units', 'DISTINCT resource_id', { entitlement_id => $into->id } )
                ->arrays->flatten->each;
        }
        # Every resource lock in id order, so two converts never deadlock.
        my %locked = map { $_ => Registry::DAO::Resource->locked( $db, $_ ) }
            sort keys %{ { map { $_ => 1 } $resource_id, @from } };
        my $live = __PACKAGE__->live_sql('holds');
        $db->query( "UPDATE holds SET state = 'converted' WHERE id = ? AND $live", $id )->rows
            or croak "hold $id is not live: it lapsed, was released or was converted";

        unless ($moving) {
            $entitlement = Registry::DAO::Entitlement->grant( $db,
                { %$into, resource_id => $resource_id, units => $units } );
            $tx->commit if $tx;
            return $entitlement;
        }

        $db->delete( 'entitlement_units', { entitlement_id => $into->id } );
        my $resource = $locked{$resource_id};
        my %held     = map { $_ => 1 } $resource->held_units($db)->@*;
        my @free     = grep { !$held{$_} } 1 .. $resource->capacity;
        $db->insert( 'entitlement_units', { entitlement_id => $into->id, resource_id => $resource_id, unit => $_ } )
            for @free[ 0 .. $units - 1 ];
        # Expiring with its occurrence, it now ends with the new one: ending
        # with the old, the new occurrence's seats would free early and resell.
        if ( $resource->event_id
            && ( $entitlement->offer_version($db)->policies->{expiry}{kind} // '' ) eq 'end_of_occurrence' ) {
            my ( undef, $ends ) = $resource->occurrence_window($db);
            $db->query( q{UPDATE entitlements SET in_effect = tstzrange(lower(in_effect), ?, '[)') WHERE id = ?},
                $ends, $into->id );
        }
        $tx->commit if $tx;
        return $entitlement;
    }

    # Gives the units back before the hold lapses; only a held hold can be.
    method release ($db) {
        return $self->update( $db, { state => 'released' }, { id => $id, state => 'held' } );
    }
}

1;
