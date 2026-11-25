#!/usr/bin/env perl
# ABOUTME: The in-studio-schedule workflow generates a class's occurrences, driven through the real WorkflowProcessor.
# ABOUTME: Each slot is an events row at the studio's local wall time with its own finite resource of the class's seats.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( import_all_workflows join_tenant );
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO;
use Registry::DAO::Event;
use Registry::DAO::Offer;
use Registry::DAO::Project;
use Registry::DAO::Resource;
use Registry::DAO::Workflow;
use Registry::Utility::WorkflowProcessor;
use Registry::WorkflowStepClasses;
use Registry::PriceOps::Hold;
use Mojo::JSON qw( decode_json encode_json );
use POSIX ();

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

my $SLUG = 'clay_studio';
import_all_workflows($dao);
Test::Registry::Fixtures::create_tenant( $dao, { name => 'Clay Studio', slug => $SLUG } );
my $tenant_dao = Registry::DAO->new( url => $test_db->uri, schema => $SLUG );
my $tdb        = $tenant_dao->db;
import_all_workflows($tenant_dao);

my %user;
for my $role (qw( admin staff parent )) {
    $user{$role} = Test::Registry::Fixtures::create_user( $dao,
        { username => "clay_$role", name => "Clay \u$role", email => "$role\@clay.test", user_type => $role } );
    join_tenant( $dao, $user{$role}, $role, $SLUG );
    # A teacher must be a user of this schema: events.teacher_id references it.
    $dao->db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)', $SLUG, $user{$role}->id );
}

my $room  = Test::Registry::Fixtures::create_location( $tdb,
    { name => 'Clay room', slug => 'clay-room', time_zone => 'America/New_York' } );
my $annex = Test::Registry::Fixtures::create_location( $tdb,
    { name => 'Clay annex', slug => 'clay-annex', time_zone => 'America/New_York' } );

my $workflow = $tenant_dao->find( Workflow => { slug => 'in-studio-schedule' } );

# Another tenant's class, location and staff member, and the platform's.
Test::Registry::Fixtures::create_tenant( $dao, { name => 'Glaze Studio', slug => 'glaze_studio' } );
my $gdb = Registry::DAO->new( url => $test_db->uri, schema => 'glaze_studio' )->db;
my %foreign;
for my $where ( [ glaze => $gdb, 'glaze_studio' ], [ registry => $dao->db, 'registry' ] ) {
    my ( $name, $handle, $slug ) = @$where;
    my $teacher = Test::Registry::Fixtures::create_user( $dao,
        { username => "${name}_staff", name => "\u$name Staff", email => "staff\@$name.test", user_type => 'staff' } );
    join_tenant( $dao, $teacher, 'staff', $slug );
    # In this schema too, so only the role check can refuse them.
    $dao->db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)', $SLUG, $teacher->id );
    my $location = Test::Registry::Fixtures::create_location( $handle, { name => "\u$name room", slug => "$name-room" } );
    my $class    = Registry::DAO::Project->create( $handle,
        { name => "\u$name class", seats_per_occurrence => 8, metadata => { location_id => $location->id } } );
    $foreign{$name} = { teacher => $teacher, location => $location, class => $class };
}

# A fresh class of $seats seats per occurrence at the room.
sub new_class ( $seats = 8 ) {
    state $n = 0;
    ++$n;
    return Registry::DAO::Project->create( $tdb, {
        name => "Throwing $n", seats_per_occurrence => $seats, metadata => { location_id => $room->id },
    } );
}

sub start ( $who = 'admin', $handle = $tenant_dao ) {
    return Registry::WorkflowProcessor->new( dao => $handle )
        ->new_run( $workflow, { user => { id => $user{$who}->id, name => $user{$who}->name } } );
}

sub schedule_step () { $workflow->get_step( $tdb, { slug => 'schedule' } ) }

# A Saturday 10:00, 90-minute schedule for $class, with fields overridden.
sub pattern ( $class, %override ) {
    return {
        class_project_id => $class->id,
        teacher_id       => $user{staff}->id,
        weekdays         => ['saturday'],
        start_time       => '10:00',
        duration         => 90,
        first_date       => '2027-01-02',
        last_date        => '2027-01-23',
        %override,
    };
}

# Runs the schedule step as $who with $fields; returns the run and the result.
sub generate ( $fields, $who = 'admin', $handle = $tdb ) {
    my $run = start($who);
    return ( $run, $run->process( $handle, schedule_step(), $fields ) );
}

sub errors_of ($result) { join ' ', ( $result->{errors} // [] )->@* }

sub occurrences_of ($class) {
    return [ Registry::DAO::Event->find( $tdb, { project_id => $class->id }, { -asc => 'time' } ) ];
}

sub local_starts ($class) { [ map { $_->local_start($tdb)->{start} } occurrences_of($class)->@* ] }

subtest 'the workflow is one schedule step, admin only' => sub {
    ok $workflow, 'in-studio-schedule is imported into the tenant' or return;
    my @slugs;
    for ( my $s = $workflow->first_step($tdb) ; $s ; $s = $s->next_step($tdb) ) { push @slugs, $s->slug }
    is_deeply \@slugs, [qw( schedule complete )], 'schedule, then complete';
    is_deeply $workflow->roles, ['admin'], 'its role entry is admin';
    ok Registry::WorkflowStepClasses::is_allowed('Registry::DAO::WorkflowSteps::GenerateOccurrences'),
        'GenerateOccurrences is on the step-class allowlist';
};

subtest 'a weekly Saturday 10:00 class over four weeks yields four occurrences with the class capacity' => sub {
    my $class = new_class(8);
    my $offer = Registry::DAO::Offer->create( $tdb, { name => 'One seat of ' . $class->name } )
        ->draft( $tdb, offer_terms( undef, class_project_id => $class->id ) )->publish($tdb);
    my ( $run, $result ) = generate( pattern($class) );
    is errors_of($result), '', 'the schedule is accepted' or return;

    is_deeply local_starts($class),
        [ '2027-01-02 10:00', '2027-01-09 10:00', '2027-01-16 10:00', '2027-01-23 10:00' ],
        'four Saturdays at 10:00 local';
    for my $event ( occurrences_of($class)->@* ) {
        my $row = $tdb->select( 'events', '*', { id => $event->id } )->hash;
        is $row->{location_id}, $room->id,         'at the class\'s location, the form\'s default';
        is $row->{teacher_id},  $user{staff}->id,  'taught by the chosen teacher';
        is $row->{duration},    90,                'for the stated minutes';
        is $row->{status},      'published',       'published';
        is $row->{capacity},    8,                 'with the class\'s seats';
        my ($resource) = Registry::DAO::Resource->find( $tdb, { event_id => $event->id } );
        ok $resource, 'with its own resource' or next;
        is $resource->kind,     'finite', 'a finite one';
        is $resource->capacity, 8,        'of the class\'s seats';
        ok $offer->buys( $tdb, $resource->id ), 'covered by the class offer with no new version';
    }
    is $result->{schedule_report}{created}, 4, 'the run reports four created';
    is $result->{schedule_report}{skipped}, 0, 'and none skipped';
};

subtest 'a range across the March DST change keeps 10:00 local' => sub {
    my $class = new_class();
    my ( undef, $result ) = generate( pattern( $class, weekdays => [qw( saturday sunday )],
        first_date => '2027-03-06', last_date => '2027-03-21' ) );
    is errors_of($result), '', 'accepted' or return;
    is_deeply local_starts($class),
        [ map { "2027-03-$_ 10:00" } qw( 06 07 13 14 20 21 ) ], 'every weekend day at 10:00 local';
    is_deeply [ map { $_->local_start($tdb)->{utc_offset} } occurrences_of($class)->@* ],
        [ ('-05:00') x 3, ('-04:00') x 3 ], 'EST before the change, EDT after';
    is_deeply $result->{schedule_report}{shifted}, [], 'and nothing is reported shifted';
};

subtest 're-running an overlapping range adds only the missing occurrences' => sub {
    my $class = new_class();
    generate( pattern($class) );
    my @before = map { $_->id } occurrences_of($class)->@*;
    my ( undef, $result ) = generate( pattern( $class, first_date => '2027-01-16', last_date => '2027-02-06' ) );
    is errors_of($result), '', 'accepted' or return;
    is_deeply local_starts($class), [ map { "$_ 10:00" } qw( 2027-01-02 2027-01-09 2027-01-16 2027-01-23
        2027-01-30 2027-02-06 ) ], 'six Saturdays, none twice';
    is_deeply [ grep { my $id = $_; grep { $_ eq $id } @before } map { $_->id } occurrences_of($class)->@* ], \@before,
        'the first run\'s occurrences are still there';
    is $tdb->query( 'SELECT count(*) FROM resources r JOIN events e ON e.id = r.event_id WHERE e.project_id = ?',
        $class->id )->array->[0], 6, 'one resource each';
    is $result->{schedule_report}{created}, 2, 'the run reports two created';
    is $result->{schedule_report}{skipped}, 2, 'and two skipped';
};

subtest 'a chosen location overrides the class\'s' => sub {
    my $class = new_class();
    my ( undef, $result ) = generate( pattern( $class, location_id => $annex->id ) );
    is errors_of($result), '', 'accepted';
    is_deeply [ map { $_->location_id } occurrences_of($class)->@* ], [ ( $annex->id ) x 4 ], 'every occurrence at the annex';
};

subtest 'an occurrence with no capacity gets its class seats' => sub {
    my $class = new_class(12);
    my $event = Registry::DAO::Event->create( $tdb, {
        project_id => $class->id, location_id => $room->id, teacher_id => $user{staff}->id,
        time => '2027-05-01T14:00:00Z', duration => 60,
    } );
    my $resource = Registry::DAO::Resource->for_occurrence( $tdb, $event->id );
    is $resource->capacity, 12, 'a 12-seat resource from the class\'s default seats';
};

subtest 'only a tenant admin generates occurrences' => sub {
    my $class = new_class();
    for my $who (qw( staff parent )) {
        my ( undef, $result ) = generate( pattern($class), $who );
        like errors_of($result), qr/administrator/, "$who is refused";
    }
    is scalar occurrences_of($class)->@*, 0, 'and nothing is created';
};

subtest 'a teacher is required and must be staff or admin here' => sub {
    my $class = new_class();
    for my $case ( [ 'no', '' ], [ 'a parent', $user{parent}->id ], [ 'a malformed', 'nope' ] ) {
        my ( undef, $result ) = generate( pattern( $class, teacher_id => $case->[1] ) );
        like errors_of($result), qr/teacher/i, "$case->[0] teacher is refused";
    }
    is scalar occurrences_of($class)->@*, 0, 'and nothing is created';
};

sub count_of ($class) { scalar occurrences_of($class)->@* }

sub events_anywhere () {
    return $tdb->query('SELECT count(*) FROM events')->array->[0]
        + $gdb->query('SELECT count(*) FROM events')->array->[0]
        + $dao->db->query('SELECT count(*) FROM registry.events')->array->[0];
}

subtest 'another tenant\'s or the platform\'s class is refused' => sub {
    my $before = events_anywhere();
    for my $name (qw( glaze registry )) {
        my ( undef, $result ) = generate( { pattern( new_class() )->%*, class_project_id => $foreign{$name}{class}->id } );
        like errors_of($result), qr/Choose one of your classes/, "$name\'s class is refused";
    }
    is events_anywhere(), $before, 'and no occurrence is created';
};

subtest 'another tenant\'s or the platform\'s location is refused' => sub {
    my $class  = new_class();
    my $before = events_anywhere();
    for my $name (qw( glaze registry )) {
        my ( undef, $result ) = generate( pattern( $class, location_id => $foreign{$name}{location}->id ) );
        like errors_of($result), qr/Choose one of your locations/, "$name\'s location is refused";
    }
    is events_anywhere(), $before, 'and no occurrence is created';
};

subtest 'another tenant\'s or the platform\'s teacher is refused' => sub {
    my $class  = new_class();
    my $before = events_anywhere();
    for my $name (qw( glaze registry )) {
        my ( undef, $result ) = generate( pattern( $class, teacher_id => $foreign{$name}{teacher}->id ) );
        like errors_of($result), qr/Choose a teacher from your staff/, "$name\'s staff member is refused";
    }
    is events_anywhere(), $before, 'and no occurrence is created';
};

sub utc_of ($event) {
    $tdb->query( q{SELECT to_char(time AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI"Z"') FROM events WHERE id = ?},
        $event->id )->array->[0];
}

subtest 'invalid schedule refused creating nothing' => sub {
    my $class = new_class();
    for my $case (
        [ 'an end date before the start', { first_date => '2027-01-23', last_date => '2027-01-02' }, qr/before the first/ ],
        [ 'an empty set of days',          { weekdays => [] },                                        qr/weekday/ ],
        [ 'a zero duration',               { duration => 0 },                                         qr/duration/ ],
        [ 'a negative duration',           { duration => -30 },                                       qr/duration/ ],
    ) {
        my ( undef, $result ) = generate( pattern( $class, $case->[1]->%* ) );
        ok $result->{stay}, "$case->[0] keeps the run on the form";
        like errors_of($result), $case->[2], "$case->[0] is refused with a message";
    }
    is count_of($class), 0, 'and nothing is created';
};

subtest 'nonexistent local time follows stated rule' => sub {
    my $class = new_class();
    my ( undef, $result ) = eval { generate( pattern( $class, weekdays => ['sunday'], start_time => '02:30',
        first_date => '2027-03-14', last_date => '2027-03-14' ) ) };
    is $@, '', 'the run does not die';
    is errors_of($result), '', 'and is accepted';
    my @events = occurrences_of($class)->@*;
    is scalar @events, 1, 'the occurrence is neither dropped nor doubled' or return;
    is $events[0]->local_start($tdb)->{start}, '2027-03-14 03:30', 'it moves forward by the gap, to 03:30 local';
    is utc_of( $events[0] ), '2027-03-14T07:30Z', 'the instant 02:30 EST names';
    is_deeply $result->{schedule_report}{shifted}, [ { asked => '2027-03-14 02:30', local_start => '2027-03-14 03:30' } ],
        'the run reports the shift';
};

subtest 'ambiguous local time yields one occurrence' => sub {
    my $class = new_class();
    my ( undef, $result ) = generate( pattern( $class, weekdays => ['sunday'], start_time => '01:30',
        first_date => '2027-11-07', last_date => '2027-11-07' ) );
    is errors_of($result), '', 'accepted';
    my @events = occurrences_of($class)->@*;
    is scalar @events, 1, 'exactly one occurrence' or return;
    is utc_of( $events[0] ), '2027-11-07T05:30Z', 'at the earlier instant';
    is $events[0]->local_start($tdb)->{utc_offset}, '-04:00', 'which is EDT';
    is_deeply $result->{schedule_report}{shifted}, [], 'and is not reported shifted';
    generate( pattern( $class, weekdays => ['sunday'], start_time => '01:30',
        first_date => '2027-11-07', last_date => '2027-11-07' ) );
    is count_of($class), 1, 'a re-run adds no second one';
};

# Waits until a session is blocked behind backend $holder, or child $pid
# exits; returns whether one waited.
sub blocked_behind ( $holder, $pid ) {
    my ( $blocked, $deadline ) = ( 0, time + 30 );
    until ( $blocked || waitpid( $pid, POSIX::WNOHANG() ) || time > $deadline ) {
        select undef, undef, undef, 0.05;
        $blocked = $tdb->query( 'SELECT count(*) FROM pg_stat_activity WHERE ? = ANY (pg_blocking_pids(pid))',
            $holder )->array->[0];
    }
    return $blocked;
}

# Two real connections. A opens a transaction and runs $first, which takes
# the class's lock; B (a forked child, building nothing from the parent's
# connection) then runs the schedule step for $run with $fields and waits on
# it. Once B waits, A commits. Returns whether B waited, A's return and B's
# result (errors, died, report).
sub race ( $first, $run, $fields ) {
    my $step = schedule_step();
    my $uri  = $test_db->uri;
    pipe( my $child_reads, my $parent_writes ) or die "pipe: $!";
    pipe( my $parent_reads, my $child_writes ) or die "pipe: $!";
    my $pid = fork() // die "fork: $!";
    unless ($pid) {
        close $_ for $parent_writes, $parent_reads;
        readline $child_reads;
        my $bdb    = Registry::DAO->new( url => $uri, schema => $SLUG )->db;
        my $result = eval { $run->process( $bdb, $step, $fields ) } // { died => "$@" };
        print $child_writes encode_json( { errors => $result->{errors}, died => $result->{died},
            report => $result->{schedule_report} } );
        close $child_writes;
        POSIX::_exit(0);
    }
    close $_ for $child_reads, $child_writes;
    my $adb    = Registry::DAO->new( url => $uri, schema => $SLUG )->db;
    my $tx     = $adb->begin;
    my $a      = $first->( $adb, $step );
    my $holder = $adb->query('SELECT pg_backend_pid()')->array->[0];
    print $parent_writes "go\n";
    $parent_writes->flush;
    my $blocked = blocked_behind( $holder, $pid );
    $tx->commit;
    waitpid $pid, 0;
    return ( $blocked, $a, decode_json( do { local $/; readline $parent_reads } ) );
}

subtest 'concurrent generation creates no duplicates' => sub {
    my $class = new_class();
    my ( $first, $second ) = ( start(), start() );
    my ( $blocked, $a, $b ) = race( sub ( $adb, $step ) { $first->process( $adb, $step, pattern($class) ) },
        $second, pattern($class) );
    ok $blocked, 'the second run waits for the first';
    is errors_of($a), '', 'the first run shows no error';
    is $b->{died}, undef, 'the second run does not die';
    is_deeply $b->{errors}, undef, 'and shows no error';
    is count_of($class), 4, 'four occurrences, none twice';
    is_deeply [ $a->{schedule_report}{created}, $b->{report}{created}, $b->{report}{skipped} ], [ 4, 0, 4 ],
        'the first created them and the second skipped them';
};

subtest 'a class deleted while the run waits for it is refused' => sub {
    my $class = new_class();
    my ( $blocked, undef, $b ) = race( sub ( $adb, $step ) { $adb->delete( 'projects', { id => $class->id } ) },
        start(), pattern($class) );
    ok $blocked, 'the run waits on the deletion';
    is $b->{died}, undef, 'and does not die';
    like join( ' ', ( $b->{errors} // [] )->@* ), qr/Choose one of your classes/, 'it is refused with the step\'s message';
    is $tdb->query( 'SELECT count(*) FROM events WHERE project_id = ?', $class->id )->array->[0], 0,
        'and nothing is created';
};

subtest 'a running generation does not hold up inserts that reference the class' => sub {
    my $class = new_class();
    my $adb   = Registry::DAO->new( url => $test_db->uri, schema => $SLUG )->db;
    my $tx    = $adb->begin;
    is errors_of( start()->process( $adb, schedule_step(), pattern($class) ) ), '', 'a run holds the class mid-transaction';
    my $other = Registry::DAO->new( url => $test_db->uri, schema => $SLUG )->db;
    $other->query(q{SET statement_timeout = '3s'});
    my $inserted = eval {
        Registry::DAO::Event->create( $other, {
            project_id => $class->id, location_id => $room->id, teacher_id => $user{staff}->id,
            time => '2027-06-05T14:00:00Z', duration => 60, capacity => 8,
        } );
        1;
    };
    ok $inserted, 'another connection still inserts an event for the class' or diag $@;
    $tx->commit;
};

subtest 'regeneration leaves booked occurrences untouched' => sub {
    my $class = new_class(8);
    my ($run) = generate( pattern($class) );
    my ($booked) = Registry::DAO::Resource->find( $tdb, { event_id => occurrences_of($class)->[0]->id } );
    my $hold = Registry::PriceOps::Hold->place( $tdb, {
        resource_id => $booked->id, units => 3, workflow_run_id => $run->id,
        expires_at  => \"now() + interval '15 minutes'",
    } );
    my $snapshot = sub {
        $tdb->query( q{
            SELECT jsonb_build_object('events', (SELECT jsonb_agg(to_jsonb(e) ORDER BY e.time) FROM events e WHERE e.project_id = ?),
                                      'resources', (SELECT jsonb_agg(to_jsonb(r) ORDER BY r.id) FROM resources r
                                                      JOIN events e ON e.id = r.event_id WHERE e.project_id = ?),
                                      'holds', (SELECT jsonb_agg(to_jsonb(h)) FROM holds h WHERE h.resource_id = ?))
        }, $class->id, $class->id, $booked->id )->expand->array->[0];
    };
    my $before = $snapshot->();
    # A later default must not reach occurrences that already exist.
    $class->update( $tdb, { seats_per_occurrence => 10 } );
    my ( undef, $result ) = generate( pattern( $class, last_date => '2027-01-30' ) );
    is errors_of($result), '', 'the overlapping re-run is accepted';
    my $after = $snapshot->();
    is_deeply [ $after->{events}->@[ 0 .. 3 ] ],    $before->{events},    'the existing occurrences are unchanged';
    is_deeply [ grep { $_->{event_id} ne $after->{events}[4]{id} } $after->{resources}->@* ], $before->{resources},
        'their resources are unchanged';
    is_deeply $after->{holds}, $before->{holds}, 'the held seats are unchanged';
    is $booked->free_units($tdb), 5, 'five of eight seats are still free';
    is $after->{events}[4]{capacity}, 10, 'only the new occurrence takes the new default';
};

subtest 'oversized range refused' => sub {
    my $class = new_class();
    my ( undef, $result ) = generate( pattern( $class, weekdays => [ qw( monday tuesday wednesday thursday friday
        saturday sunday ) ], first_date => '2027-01-01', last_date => '2076-12-31' ) );
    like errors_of($result), qr/at most 366 days/, 'daily for 50 years is refused with a message';
    ( undef, $result ) = generate( pattern( $class, first_date => '2027-01-01', last_date => '2028-01-03' ) );
    like errors_of($result), qr/at most 366 days/, '367 days is refused';
    is count_of($class), 0, 'and nothing is inserted';
    ( undef, $result ) = generate( pattern( $class, first_date => '2027-01-01', last_date => '2028-01-02' ) );
    is errors_of($result), '', '366 days is accepted';
    is count_of($class), 53, 'a Saturday each week';
};

done_testing;
