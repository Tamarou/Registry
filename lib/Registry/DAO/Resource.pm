# ABOUTME: A PriceOps resource: something a tenant controls access to.
# ABOUTME: Finite resources carry a capacity; unbounded ones are limited only by policy.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::Resource :isa(Registry::DAO::Object) {
    use Carp qw( croak );

    field $id :param :reader;
    field $name :param :reader;
    field $kind :param :reader;    # 'finite' or 'unbounded'
    field $capacity :param :reader = undef;
    field $created_at :param :reader;

    sub table { 'resources' }

    # The resource, its row locked until the caller's transaction ends: every
    # grant and hold takes this lock first, so capacity is read and claimed
    # with no other claim in between.
    sub locked ( $class, $db, $id ) {
        my $row = $db->query( 'SELECT * FROM resources WHERE id = ? FOR UPDATE', $id )->hash;
        croak "no resource $id here" unless $row;
        return $class->new(%$row);
    }

    # Refuses $wanted units unless it is a whole number of at least one and
    # that many are free. Call it holding locked()'s lock.
    method claim ( $db, $wanted ) {
        croak "$name ($id) is unbounded: it has no units to hold" unless $kind eq 'finite';
        croak "a claim on $name ($id) holds at least one unit"
            unless defined $wanted && $wanted =~ /\A[1-9][0-9]*\z/;
        my $free = $self->free_units($db);
        croak sprintf '%s (%s) has %d of %d units free: %d asked for',
            $name, $id, $free, $capacity, $wanted
            if $wanted > $free;
    }

    # Unit numbers held by entitlements in effect now or later, by the one
    # in-effect rule: ended ones free theirs at once.
    method held_units ($db) {
        $db = $db->db if $db isa Registry::DAO;
        require Registry::DAO::Entitlement;
        my $in_effect = Registry::DAO::Entitlement->in_effect_sql( 'e', 'tstzrange(now(), NULL)' );
        return $db->query( qq{
            SELECT u.unit FROM entitlement_units u JOIN entitlements e ON e.id = u.entitlement_id
             WHERE u.resource_id = ? AND $in_effect
             ORDER BY u.unit
        }, $id )->arrays->flatten->to_array;
    }

    # How many units are free right now: capacity less units held by
    # entitlements and by live holds (held and not yet lapsed).
    method free_units ($db) {
        $db = $db->db if $db isa Registry::DAO;
        my $on_hold = $db->query( q{
            SELECT coalesce(sum(units), 0) FROM holds
             WHERE resource_id = ? AND state = 'held' AND expires_at > now()
        }, $id )->array->[0];
        return $capacity - $self->held_units($db)->@* - $on_hold;
    }
}

1;
