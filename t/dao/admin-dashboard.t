use 5.42.0;
use lib          qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is isnt ok like is_deeply subtest note )];
defer { done_testing };

use Test::Registry::DB;
use Test::Registry::Helpers;
use Test::Registry::Fixtures;
use Registry::DAO::Family;
use Registry::DAO::AdminDashboard;
use Registry::DAO::Waitlist;

# Every assertion in this file used to be against SQL the test wrote itself. It
# never once called Registry::DAO::AdminDashboard -- ten inline db->query calls,
# each re-implementing a dashboard query and then grading its own copy. So the
# DAO could say anything at all and this file stayed green: `get_export_data`'s
# attendance branch selected `ev.name` and `ev.start_time`, columns that do not
# exist, and raised on every call; `get_enrollment_alerts` divided by
# `events.capacity`, which nothing writes, and had never reported a single
# session (#408). Neither was visible from here.
#
# One assertion was purer still: it computed `$attendance_status` in the test and
# then asserted it matched /^(completed|missing|pending)$/ -- the three values it
# had just assigned.
#
# What follows calls the DAO and asserts exact numbers against a known fixture.

# Setup test database
my $t  = Test::Registry::DB->new;
my $db = $t->db;

# Create a test tenant (in registry schema)
my $tenant = Test::Registry::Fixtures::create_tenant($db, {
    name => 'Test Organization',
    slug => 'test_org',
});

# Create the tenant schema with all required tables
$db->db->query('SELECT clone_schema(dest_schema => ?)', $tenant->slug);

# Create test users (in registry schema)
my $admin = Test::Registry::Fixtures::create_user($db, {
    username => 'admin',
    password => 'password123',
    user_type => 'admin',
});

my $staff = Test::Registry::Fixtures::create_user($db, {
    username => 'staff',
    password => 'password123',
    user_type => 'staff',
});

my $parent = Test::Registry::Fixtures::create_user($db, {
    username => 'parent',
    password => 'password123',
    user_type => 'parent',
});

# Copy users to tenant schema
$db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $admin->id);
$db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $staff->id);
$db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $parent->id);

# Switch to tenant schema for operations
$db = $db->schema($tenant->slug);

# Add child to family
Registry::DAO::Family->add_child($db, $parent->id, {
    child_name => 'Test Child',
    birth_date => '2015-06-15',
    grade => '3rd'
});

my $children = Registry::DAO::Family->list_children($db, $parent->id);
my $child = $children->[0];

my $location = Test::Registry::Fixtures::create_location($db, {
    name => 'Test Location',
    slug => 'test-location'
});

my $program = Test::Registry::Fixtures::create_project($db, {
    name => 'Test Program'
});

# The block below queries the events falling inside today, so the session has
# to span today and its event has to land in it.
my $session = Test::Registry::Fixtures::create_session($db, {
    name => 'Test Session',
    start_date => days_from_now(-3),
    end_date => days_from_now(4)
});


my $raw = $db->db;   # DAO methods take a Mojo::Pg::Database, not a Registry::DAO

# ---------------------------------------------------------------------------
# Fixture: one active enrollment, one event today, in the session above.
# ---------------------------------------------------------------------------
my $enrollment = Test::Registry::Fixtures::create_enrollment($db, {
    session_id       => $session->id,
    student_id       => $parent->id,     # legacy column, still NOT NULL
    family_member_id => $child->id,
    status           => 'active'
});
ok $enrollment, 'Enrollment created for dashboard stats';

my $event = Test::Registry::Fixtures::create_event($db, {
    project_id  => $program->id,
    location_id => $location->id,
    teacher_id  => $staff->id,
    time        => days_from_now(0) . ' 14:00:00',
    duration    => 60
});
ok $event, 'Event created for dashboard stats';
$session->add_events($raw, $event->id);

subtest 'get_overview_stats counts what the tiles show' => sub {
    my $stats = Registry::DAO::AdminDashboard->get_overview_stats($raw);

    is $stats->{active_enrollments}, 1, 'one active enrollment';
    is $stats->{active_programs},    1, 'one programme';
    is $stats->{todays_events},      1, "the event scheduled for today";
    is $stats->{waitlist_entries},   0, 'nothing on the waitlist yet';
    is $stats->{pending_drop_requests},     0, 'no drop requests yet';
    is $stats->{pending_transfer_requests}, 0, 'no transfer requests yet';

    # Dollars, from cents, as a string -- the template prints it verbatim.
    is $stats->{monthly_revenue}, '0.00', 'no revenue before any payment';
};

subtest 'monthly revenue is what the tenant kept' => sub {
    # A cart that was charged in full, and a second one with a partial refund
    # owed. The tile must show the kept share of BOTH: filtering to 'completed'
    # dropped a whole cart the moment any child in it was owed money back, so a
    # $100 debt against a $300 cart cost the tile the entire $300.
    $raw->insert('payments', {
        user_id      => $parent->id,
        amount_cents => 30000,
        status       => 'completed',
        metadata     => '{}',
    });
    $raw->insert('payments', {
        user_id            => $parent->id,
        amount_cents       => 30000,
        refund_owed_cents  => 10000,
        status             => 'refund_pending',
        metadata           => '{}',
    });

    my $stats = Registry::DAO::AdminDashboard->get_overview_stats($raw);
    is $stats->{monthly_revenue}, '500.00',
        '$300 kept in full plus $200 kept of a $300 cart owing $100 back';
};

subtest 'get_enrollment_alerts reports a session that is nearly full' => sub {
    # The alert is measured against the SESSION's capacity, because that is what
    # an enrolment counts against. It used to divide by events.capacity -- a
    # column nothing writes -- so COUNT/NULL was NULL, NULL > 0.9 was not true,
    # and this panel had never produced a row in its life (#408).
    #
    # Future-dated: the query only looks at sessions that have not started.
    my $full = Test::Registry::Fixtures::create_session($db, {
        name       => 'Nearly Full Session',
        start_date => days_from_now(20),
        end_date   => days_from_now(27),
        capacity   => 1,
    });
    my $roomy = Test::Registry::Fixtures::create_session($db, {
        name       => 'Plenty Of Room Session',
        start_date => days_from_now(20),
        end_date   => days_from_now(27),
        capacity   => 10,
    });

    my $hour = 9;
    for my $s ($full, $roomy) {
        my $ev = Test::Registry::Fixtures::create_event($db, {
            project_id  => $program->id,
            location_id => $location->id,
            teacher_id  => $staff->id,
            time        => days_from_now(20) . sprintf(' %02d:00:00', $hour++),
            duration    => 60,
        });
        $s->add_events($raw, $ev->id);
        Test::Registry::Fixtures::create_enrollment($db, {
            session_id       => $s->id,
            student_id       => $parent->id,
            family_member_id => $child->id,
            status           => 'active',
        });
    }

    my $alerts = Registry::DAO::AdminDashboard->get_enrollment_alerts($raw);
    my %by_session = map { $_->{session_name} => $_ } @$alerts;

    ok $by_session{'Nearly Full Session'},
        'a session at capacity is reported';
    is $by_session{'Nearly Full Session'}{capacity}, 1,
        'against the session capacity, not a meeting capacity';
    is $by_session{'Nearly Full Session'}{enrolled_count}, 1, 'with its count';
    is $by_session{'Nearly Full Session'}{utilization_rate}, 100,
        'at a hundred percent';
    is $by_session{'Nearly Full Session'}{program_name}, 'Test Program',
        'named by its programme';

    ok !$by_session{'Plenty Of Room Session'},
        'a session at a tenth of capacity is not reported';
};

subtest 'get_waitlist_summary groups the queue by session' => sub {
    my $waitlist_parent = Test::Registry::Fixtures::create_user($db, {
        username  => 'waitlist_parent',
        password  => 'password123',
        user_type => 'parent',
    });
    Registry::DAO::Family->add_child($raw, $waitlist_parent->id, {
        child_name => 'Waiting Child',
        birth_date => '2015-06-15',
        grade      => '3rd',
    });
    my $waiting_child =
      Registry::DAO::Family->list_children($raw, $waitlist_parent->id)->[0];

    my $entry = Registry::DAO::Waitlist->join_waitlist(
        $raw, $session->id, $location->id,
        $waiting_child->id, $waitlist_parent->id,
    );
    ok $entry, 'Waitlist entry created for admin dashboard';

    my $summary = Registry::DAO::AdminDashboard->get_waitlist_summary($raw);
    my %by_session = map { $_->{session_name} => $_ } @$summary;

    ok $by_session{'Test Session'}, 'the session with a queue is listed';
    is $by_session{'Test Session'}{total_waiting},  1, 'one child waiting';
    is $by_session{'Test Session'}{offers_pending}, 0, 'and no offer out yet';

    # Offering the seat moves the same entry between two of the three counts, so
    # a summary that reported a constant would fail here.
    Registry::DAO::Waitlist->process_waitlist($raw, $session->id);

    my $after = Registry::DAO::AdminDashboard->get_waitlist_summary($raw);
    my %then  = map { $_->{session_name} => $_ } @$after;
    is $then{'Test Session'}{offers_pending}, 1, 'the offer is now pending';
    is $then{'Test Session'}{total_waiting},  1,
        'and the entry is still counted in the queue';

    # The overview tile counts waiting and offered alike, so it sees it too.
    my $stats = Registry::DAO::AdminDashboard->get_overview_stats($raw);
    is $stats->{waitlist_entries}, 1, 'the overview tile counts the entry';
};

subtest 'get_enrollment_trends returns chart-shaped data' => sub {
    for my $period (qw( week month quarter )) {
        my $trends =
          Registry::DAO::AdminDashboard->get_enrollment_trends($raw, $period);

        is $trends->{period}, $period, "$period: echoes the period asked for";
        is ref $trends->{labels}, 'ARRAY', "$period: labels is a list";
        is ref $trends->{data},   'ARRAY', "$period: data is a list";
        is scalar @{ $trends->{labels} }, scalar @{ $trends->{data} },
            "$period: one label per data point -- a chart cannot plot otherwise";

        # Three enrollments were created above, all just now, so every window
        # that reaches back at all has to account for them.
        my $total = 0;
        $total += $_ for @{ $trends->{data} };
        is $total, 3, "$period: counts all three enrollments made in this run";
    }
};

subtest 'get_export_data carries the rows it is an export of' => sub {
    my $rows = Registry::DAO::AdminDashboard->get_export_data($raw, 'enrollments');
    ok @$rows >= 1, 'the enrollments export has rows';
    ok( ( grep { ( $_->{child_name} // '' ) eq 'Test Child' } @$rows ),
        'including the child who is enrolled' );

    # Attendance raised on every call before #395: it selected ev.name and
    # ev.start_time, and events has neither.
    my $attendance = eval {
        Registry::DAO::AdminDashboard->get_export_data($raw, 'attendance') };
    ok defined $attendance, 'the attendance export does not raise'
        or note "raised: $@";

    my $waitlist = eval {
        Registry::DAO::AdminDashboard->get_export_data($raw, 'waitlist') };
    ok defined $waitlist, 'the waitlist export does not raise'
        or note "raised: $@";
    ok( ( grep { ( $_->{child_name} // '' ) eq 'Waiting Child' } @$waitlist ),
        'and carries the child who is waiting' );
};
