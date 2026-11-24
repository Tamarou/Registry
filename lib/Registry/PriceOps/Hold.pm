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
    # $data->{workflow_run_id} until $data->{expires_at}.
    sub place ( $class, $db, $data ) {
        $db = $db->db if $db isa Registry::DAO;
        my $tx       = $db->dbh->{AutoCommit} ? $db->begin : undef;
        my $resource = Registry::DAO::Resource->locked( $db, $data->{resource_id} );
        $resource->claim( $db, $data->{units} );
        my $hold = $class->create( $db, $data );
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
    # grants a new entitlement holding the hold's units.
    method convert ( $db, $into ) {
        $db = $db->db if $db isa Registry::DAO;
        my $tx = $db->dbh->{AutoCommit} ? $db->begin : undef;
        Registry::DAO::Resource->locked( $db, $resource_id );
        my $live = __PACKAGE__->live_sql('holds');
        $db->query( "UPDATE holds SET state = 'converted' WHERE id = ? AND $live", $id )->rows
            or croak "hold $id is not live: it lapsed, was released or was converted";
        my $entitlement = Registry::DAO::Entitlement->grant( $db,
            { %$into, resource_id => $resource_id, units => $units } );
        $tx->commit if $tx;
        return $entitlement;
    }

    # Gives the units back before the hold lapses; only a held hold can be.
    method release ($db) {
        return $self->update( $db, { state => 'released' }, { id => $id, state => 'held' } );
    }
}

1;
