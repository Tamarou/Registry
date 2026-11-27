# ABOUTME: A PriceOps resource: something a tenant controls access to.
# ABOUTME: Finite resources carry a capacity; unbounded ones are limited only by policy.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::Resource :isa(Registry::DAO::Object) {
    use Carp qw( croak );
    use List::Util qw( uniq );

    field $id :param :reader;
    field $name :param :reader;
    field $kind :param :reader;    # 'finite' or 'unbounded'
    field $capacity :param :reader = undef;
    field $event_id :param :reader = undef;    # the occurrence it is, if any
    field $waitlist :param :reader = { kind => 'none' };    # none, or a queue with offer_hold_hours
    field $created_at :param :reader;

    sub table { 'resources' }

    # The finite resource that is occurrence $event_id, with the event's seats,
    # or its class's default seats when the event states none.
    sub for_occurrence ( $class, $db, $event_id ) {
        $db = $db->db if $db isa Registry::DAO;
        my $row = $db->query( q{
            INSERT INTO resources (name, kind, capacity, event_id)
            SELECT p.name || ' ' || e.time, 'finite', COALESCE(e.capacity, p.seats_per_occurrence), e.id
              FROM events e JOIN projects p ON p.id = e.project_id
             WHERE e.id = ?
            RETURNING *
        }, $event_id )->expand->hash;
        croak "no event $event_id here" unless $row;
        return $class->new(%$row);
    }

    # A session: one finite resource of $data->{capacity} seats whose days are
    # its events, one published event per date in $data->{days} (at least
    # one), each at $data->{start} (HH:MM) in the location's zone for
    # $data->{minutes}. A start that does not exist on a day (the spring DST
    # gap) moves forward, by GenerateOccurrences' rule. In list context also
    # returns those days as [ { asked, local_start } ], as that step reports them.
    sub create_session ( $class, $db, $data ) {
        $db = $db->db if $db isa Registry::DAO;
        require Registry::DAO::WorkflowSteps::GenerateOccurrences;
        croak 'a session has at least one day' unless ref $data->{days} eq 'ARRAY' && $data->{days}->@*;
        my $zone = $db->select( 'locations', 'time_zone', { id => $data->{location_id} } )->array
            or croak "no location $data->{location_id} here";

        my $tx      = $db->dbh->{AutoCommit} ? $db->begin : undef;
        my $session = $class->create( $db, {
            name     => $data->{name},
            kind     => 'finite',
            capacity => $data->{capacity},
            waitlist => { -json => $data->{waitlist} // { kind => 'none' } },
        } );
        my @shifted;
        for my $day ( $data->{days}->@* ) {
            my $local = "$day $data->{start}";
            my $slot  = Registry::DAO::WorkflowSteps::GenerateOccurrences->instant( $db, $local, $zone->[0] );
            push @shifted, { asked => $local, local_start => $slot->{local_start} } if $slot->{shifted};
            $db->insert( 'events', {
                project_id => $data->{project_id}, location_id => $data->{location_id},
                teacher_id => $data->{teacher_id}, time => $slot->{instant}, duration => $data->{minutes},
                capacity   => $data->{capacity}, status => 'published', session_resource_id => $session->id,
            } );
        }
        $tx->commit if $tx;
        return wantarray ? ( $session, \@shifted ) : $session;
    }

    # Its days (events) as { id, time, duration }, in time order; none unless
    # it is a session.
    method session_days ($db) {
        $db = $db->db if $db isa Registry::DAO;
        return $db->select( 'events', [qw( id time duration )], { session_resource_id => $id }, 'time' )
            ->hashes->to_array;
    }

    method is_session ($db) { !!$self->session_days($db)->@* }

    # The sessions of program $project_id, by first day, then name.
    sub sessions_of ( $class, $db, $project_id ) {
        $db = $db->db if $db isa Registry::DAO;
        return $db->query( q{
            SELECT r.* FROM resources r
              JOIN (SELECT session_resource_id, min(time) AS first FROM events
                     WHERE project_id = ? AND session_resource_id IS NOT NULL GROUP BY session_resource_id) d
                ON d.session_resource_id = r.id
             ORDER BY d.first, r.name
        }, $project_id )->expand->hashes->map( sub { $class->new(%$_) } )->to_array;
    }

    # Whether every one of @ids names a resource here with days: an
    # occurrence's event or a session's. None named is not.
    sub all_have_days ( $class, $db, @ids ) {
        $db = $db->db if $db isa Registry::DAO;
        my @distinct = uniq @ids or return 0;
        return $db->query( q{
            SELECT count(DISTINCT r.id) FROM resources r
              JOIN events e ON e.id = r.event_id OR e.session_resource_id = r.id
             WHERE r.id::text = ANY(?)
        }, \@distinct )->array->[0] == @distinct;
    }

    # The events it is: its occurrence's one, or a session's days. The one
    # WHERE every window and sale question reads them through.
    my $EVENTS = 'FROM events WHERE id = ? OR session_resource_id = ?';

    # Its start and end instants: an occurrence's, or from a session's first
    # day's start to its last day's end. The one place they are computed.
    method occurrence_window ($db) {
        $db = $db->db if $db isa Registry::DAO;
        my @window = $db->query( "SELECT min(time), max(time + duration * interval '1 minute') $EVENTS",
            $event_id, $id )->array->@*;
        croak "$name ($id) is neither an occurrence nor a session" unless defined $window[0];
        return @window;
    }

    # Whether a booking may take seats now: every one of its events is
    # published and the first is still to start. Coverage
    # (OfferVersion->covered_resources) ignores both, so the booking steps ask
    # this as well.
    method on_sale ($db) {
        $db = $db->db if $db isa Registry::DAO;
        return !!$db->query( "SELECT bool_and(status = 'published') AND clock_timestamp() < min(time) $EVENTS",
            $event_id, $id )->array->[0];
    }

    # The resource, its row locked until the caller's transaction ends: every
    # grant and hold takes this lock first, so capacity is read and claimed
    # with no other claim in between.
    sub locked ( $class, $db, $id ) {
        my $row = $db->query( 'SELECT * FROM resources WHERE id = ? FOR UPDATE', $id )->expand->hash;
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
        require Registry::PriceOps::Hold;
        my $live    = Registry::PriceOps::Hold->live_sql('holds');
        my $on_hold = $db->query( qq{
            SELECT coalesce(sum(units), 0) FROM holds WHERE resource_id = ? AND $live
        }, $id )->array->[0];
        return $capacity - $self->held_units($db)->@* - $on_hold;
    }
}

1;
