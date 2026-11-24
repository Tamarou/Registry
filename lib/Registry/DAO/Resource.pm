# ABOUTME: A PriceOps resource: something a tenant controls access to.
# ABOUTME: Finite resources carry a capacity; unbounded ones are limited only by policy.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::Resource :isa(Registry::DAO::Object) {
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
        return $row && $class->new(%$row);
    }

    # Unit numbers held by entitlements in effect now or later; ended ones
    # free theirs.
    # shortcut: reads the period alone, as no state exists yet; 01a20448-1177
    # rewires this to the one in-effect predicate.
    method held_units ($db) {
        $db = $db->db if $db isa Registry::DAO;
        return $db->query( q{
            SELECT u.unit FROM entitlement_units u JOIN entitlements e ON e.id = u.entitlement_id
             WHERE u.resource_id = ? AND (upper_inf(e.in_effect) OR upper(e.in_effect) > now())
             ORDER BY u.unit
        }, $id )->arrays->flatten->to_array;
    }

    # How many units are free right now.
    method free_units ($db) {
        return $capacity - $self->held_units($db)->@*;
    }
}

1;
