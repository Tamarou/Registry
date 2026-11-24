# ABOUTME: A time-limited hold on N units of a finite resource, for the workflow run that placed it.
# ABOUTME: Live while held and before expires_at; placed under the resource lock, so it never overruns capacity.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::PriceOps::Hold :isa(Registry::DAO::Object) {
    use Carp qw( croak );
    use Registry::DAO::Resource;

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
        my $free     = $resource->free_units($db);
        croak sprintf '%s (%s) has %d of %d units free: %d asked for',
            $resource->name, $resource->id, $free, $resource->capacity, $data->{units}
            if $data->{units} > $free;
        my $hold = $class->create( $db, $data );
        $tx->commit if $tx;
        return $hold;
    }

    # Gives the units back before the hold lapses; only a held hold can be.
    method release ($db) {
        return $self->update( $db, { state => 'released' }, { id => $id, state => 'held' } );
    }
}

1;
