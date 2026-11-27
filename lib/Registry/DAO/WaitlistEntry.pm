# ABOUTME: A child's place in a session resource's waitlist: a first-come queue ordered by joined_at, then id.
# ABOUTME: Entries move waiting -> offered -> accepted or lapsed, or leave; each move is from its legal predecessor only.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WaitlistEntry :isa(Registry::DAO::Object) {
    use Registry::DAO::Entitlement;

    field $id :param :reader;
    field $resource_id :param :reader;
    field $family_member_id :param :reader;
    field $payer_user_id :param :reader;
    field $joined_at :param :reader;
    field $state :param :reader;    # waiting, offered, accepted, lapsed or left
    field $hold_id :param :reader = undef;
    field $workflow_run_id :param :reader = undef;
    field $offered_at :param :reader = undef;

    sub table { 'waitlist_entries' }

    sub refuse ($why) { Registry::DAO::Entitlement::Refused->throw("$why\n") }

    # Puts $data->{family_member_id} at the back of $data->{resource_id}'s
    # line, paid for by $data->{payer_user_id}. Refused unless the resource
    # keeps a queue, or while the child is already waiting or offered there.
    sub join ( $class, $db, $data ) {
        $db = $db->db if $db isa Registry::DAO;
        my $kind = $db->query( q{SELECT waitlist->>'kind' FROM resources WHERE id = ?}, $data->{resource_id} )
            ->array;
        refuse("resource $data->{resource_id} keeps no waitlist") unless $kind && $kind->[0] eq 'queue';
        my $row = $db->query( q{
            INSERT INTO waitlist_entries (resource_id, family_member_id, payer_user_id) VALUES (?, ?, ?)
            ON CONFLICT (resource_id, family_member_id) WHERE state IN ('waiting', 'offered') DO NOTHING
            RETURNING *
        }, @$data{qw( resource_id family_member_id payer_user_id )} )->hash;
        refuse("child $data->{family_member_id} is already in line for $data->{resource_id}") unless $row;
        return $class->new(%$row);
    }

    # The first waiting entry in $resource_id's line, its row locked until the
    # caller's transaction ends; undef when nobody waits.
    sub next_waiting ( $class, $db, $resource_id ) {
        $db = $db->db if $db isa Registry::DAO;
        my $row = $db->query( q{
            SELECT * FROM waitlist_entries WHERE resource_id = ? AND state = 'waiting'
             ORDER BY joined_at, id LIMIT 1 FOR UPDATE
        }, $resource_id )->hash;
        return $row ? $class->new(%$row) : undef;
    }

    # Entry $entry_id's place in its line, from 1; undef unless it is waiting.
    sub position ( $class, $db, $entry_id ) {
        $db = $db->db if $db isa Registry::DAO;
        # No row unless it is waiting.
        my $row = $db->query( q{
            SELECT count(*) FROM waitlist_entries e JOIN waitlist_entries o
                ON o.resource_id = e.resource_id AND o.state = 'waiting'
               AND (o.joined_at, o.id) <= (e.joined_at, e.id)
             WHERE e.id = ? AND e.state = 'waiting'
            HAVING count(*) > 0
        }, $entry_id )->array;
        return $row ? $row->[0] : undef;
    }

    sub waiting_count ( $class, $db, $resource_id ) {
        $db = $db->db if $db isa Registry::DAO;
        return $db->query( q{SELECT count(*) FROM waitlist_entries WHERE resource_id = ? AND state = 'waiting'},
            $resource_id )->array->[0];
    }

    # Moves it to $to, with %set, only from one of @from: a stale or repeated
    # move changes nothing and is refused.
    method move ( $db, $to, $from, %set ) {
        $db = $db->db if $db isa Registry::DAO;
        my $row = $db->update( 'waitlist_entries', { %set, state => $to },
            { id => $id, state => { -in => $from } }, { returning => '*' } )->hash;
        refuse("waitlist entry $id is not @$from, so it cannot become $to") unless $row;
        return blessed($self)->new(%$row);
    }

    # A seat held by $hold_id for checkout run $run_id is offered to it.
    method offer ( $db, $hold, $run ) {
        return $self->move( $db, 'offered', ['waiting'],
            hold_id => $hold, workflow_run_id => $run, offered_at => \'clock_timestamp()' );
    }

    method accept ($db) { $self->move( $db, 'accepted', ['offered'] ) }
    method lapse ($db)  { $self->move( $db, 'lapsed',   ['offered'] ) }
    method leave ($db)  { $self->move( $db, 'left',     [ 'waiting', 'offered' ] ) }
}

1;
