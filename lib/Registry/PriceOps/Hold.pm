# ABOUTME: A time-limited hold on N units of a finite resource, for the workflow run that placed it.
# ABOUTME: Live while held and before expires_at; placed under the resource lock, so it never overruns capacity.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::PriceOps::Hold :isa(Registry::DAO::Hold) {
    use Registry::DAO::Resource;
    use Registry::DAO::Entitlement;
    use Carp qw( croak );

    # Holds $data->{units} units of $data->{resource_id} for
    # $data->{workflow_run_id} until $data->{expires_at}, which must be later
    # than now: a zero or past lifetime is refused.
    sub place ( $class, $db, $data ) {
        $db = $db->db if $db isa Registry::DAO;
        my $tx       = $db->dbh->{AutoCommit} ? $db->begin : undef;
        my $resource = Registry::DAO::Resource->locked( $db, $data->{resource_id} );
        $resource->claim( $db, $data->{units} );
        my $hold = $class->create( $db, $data );
        croak 'a hold must expire after it is placed' unless $hold->expires_later($db);
        # The lifetime it was placed with bounds any extension (OneTimePayment).
        $hold->record_lifetime($db);
        $tx->commit if $tx;
        return $hold;
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
        my ( $id, $units, $resource_id ) = ( $self->id, $self->units, $self->resource_id );
        my $tx     = $db->dbh->{AutoCommit} ? $db->begin : undef;
        my $moving = $into isa Registry::DAO::Entitlement;
        my ( $entitlement, @from );
        if ($moving) {
            # Locked before its units are read, so a concurrent move or end waits;
            # every refusal comes before the hold is touched.
            my $current = Registry::DAO::Entitlement->lock_current( $db, $into->id );
            $entitlement = Registry::DAO::Entitlement->find( $db, { id => $into->id } );
            croak sprintf 'entitlement %s is %s: units move only onto an active one', $into->id, $entitlement->state
                unless $entitlement->state eq 'active';
            croak sprintf 'entitlement %s has ended: units move only onto a current one', $into->id
                unless $current;
            croak sprintf 'entitlement %s does not buy resource %s', $into->id, $resource_id
                unless $entitlement->offer_version($db)->buys( $db, $resource_id );
            my $has = $entitlement->unit_count($db);
            croak sprintf 'hold %s is %d units but entitlement %s holds %d: a move keeps its unit count',
                $id, $units, $into->id, $has
                unless $has == $units;
            @from = $entitlement->unit_resource_ids($db);
        }
        # Every resource lock in id order, so two converts never deadlock.
        my %locked = map { $_ => Registry::DAO::Resource->locked( $db, $_ ) }
            sort keys %{ { map { $_ => 1 } $resource_id, @from } };
        $self->mark_converted($db)
            or croak "hold $id is not live: it lapsed, was released or was converted";

        unless ($moving) {
            $entitlement = Registry::DAO::Entitlement->grant( $db,
                { %$into, resource_id => $resource_id, units => $units } );
            $tx->commit if $tx;
            return $entitlement;
        }

        $entitlement->release_units($db);
        my $resource = $locked{$resource_id};
        my %held     = map { $_ => 1 } $resource->held_units($db)->@*;
        my @free     = grep { !$held{$_} } 1 .. $resource->capacity;
        $entitlement->take_units( $db, $resource_id, @free[ 0 .. $units - 1 ] );
        # Expiring with its occurrence, it now ends with the new one: ending
        # with the old, the new occurrence's seats would free early and resell.
        if ( $resource->event_id
            && ( $entitlement->offer_version($db)->policies->{expiry}{kind} // '' ) eq 'end_of_occurrence' ) {
            my ( undef, $ends ) = $resource->occurrence_window($db);
            $entitlement->end_period_at( $db, $ends );
        }
        $tx->commit if $tx;
        return $entitlement;
    }

    # Gives the units back before the hold lapses; only a held hold can be.
    method release ($db) {
        return $self->update( $db, { state => 'released' }, { id => $self->id, state => 'held' } );
    }
}

1;
