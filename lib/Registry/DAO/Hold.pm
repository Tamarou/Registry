# ABOUTME: The holds row: a time-limited hold on N units of a finite resource, for the workflow run that placed it.
# ABOUTME: Its SQL lives here; Registry::PriceOps::Hold builds placing, converting and releasing on it.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::Hold :isa(Registry::DAO::Object) {
    field $id :param :reader;
    field $resource_id :param :reader;
    field $units :param :reader;
    field $workflow_run_id :param :reader;
    field $expires_at :param :reader;
    field $state :param :reader;    # held, converted or released

    sub table { 'holds' }

    # The one liveness rule, as SQL over hold row $h: held, and the clock has
    # not passed expires_at (inclusive, ADR 005 8b). The clock, not now(), so a
    # request that waited on the resource lock sees holds that lapsed meanwhile.
    sub live_sql ( $class, $h ) {
        return "($h.state = 'held' AND clock_timestamp() <= $h.expires_at)";
    }

    # Is expires_at still ahead of the clock?
    method expires_later ($db) {
        return $db->query( 'SELECT ?::timestamptz > clock_timestamp()', $expires_at )->array->[0];
    }

    # Records the lifetime it was placed with, which bounds any extension (OneTimePayment).
    method record_lifetime ($db) {
        $db->query( 'UPDATE holds SET lifetime = expires_at - placed_at WHERE id = ?', $id );
    }

    # Marks it converted if it is live; the number of rows changed, 0 or 1.
    method mark_converted ($db) {
        my $live = __PACKAGE__->live_sql('holds');
        return $db->query( "UPDATE holds SET state = 'converted' WHERE id = ? AND $live", $id )->rows;
    }
}

1;
