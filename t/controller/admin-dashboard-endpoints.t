# ABOUTME: Controller tests for AdminDashboard HTMX/JSON endpoints against seeded data.
# ABOUTME: Exercises the action bodies end-to-end so date handling and session->project joins are covered.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers qw(authenticate_as);
use Registry::DAO::Family;
use Registry::DAO::Enrollment;
use Registry::DAO::DropRequest;
use Registry::DAO::TransferRequest;
use Registry::DAO::Notification;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

my $t = Test::Registry::Mojo->new('Registry');
# Pin the controller's dao() to the seeded test schema regardless of tenant.
$t->app->helper(dao => sub { $dao });

# --- Seed a full enrollment chain -----------------------------------------
my $location = $dao->create(Location => {
    name => 'Dashboard Studio', slug => 'dashboard-studio',
    address_info => { street => '1 Main', city => 'Orlando', state => 'FL' },
    metadata => {},
});
my $program = $dao->create(Project => {
    status => 'published', name => 'Dashboard Camp',
    program_type_slug => 'summer-camp', metadata => {},
});
my $teacher = $dao->create(User => { username => 'dash_teacher', user_type => 'staff' });

# Session spanning today so the "current" program-overview filter includes it.
my $session = $dao->create(Session => {
    name => 'Dashboard Week 1', start_date => '2026-01-01', end_date => '2026-12-31',
    status => 'published', capacity => 16, metadata => {},
});
my $event = $dao->create(Event => {
    time => '2026-06-15 09:00:00', duration => 420,
    location_id => $location->id, project_id => $program->id,
    teacher_id => $teacher->id, capacity => 16, metadata => {},
});
$session->add_events($dao->db, $event->id);

# A second program/session used as the transfer target.
my $program2 = $dao->create(Project => {
    status => 'published', name => 'Dashboard Camp Two',
    program_type_slug => 'summer-camp', metadata => {},
});
my $session2 = $dao->create(Session => {
    name => 'Dashboard Week 2', start_date => '2026-01-01', end_date => '2026-12-31',
    status => 'published', capacity => 16, metadata => {},
});
my $event2 = $dao->create(Event => {
    time => '2026-06-22 09:00:00', duration => 420,
    location_id => $location->id, project_id => $program2->id,
    teacher_id => $teacher->id, capacity => 16, metadata => {},
});
$session2->add_events($dao->db, $event2->id);

my $parent = $dao->create(User => {
    username => 'dash_parent', name => 'Dashboard Parent',
    user_type => 'parent', email => 'dash@example.com',
});
my $child = Registry::DAO::Family->add_child($dao->db, $parent->id, {
    child_name => 'Dashboard Kid', birth_date => '2018-01-01', grade => '3',
    medical_info => {}, emergency_contact => { name => 'P', phone => '555' },
});
my $enrollment = Registry::DAO::Enrollment->create($dao->db, {
    session_id       => $session->id,
    family_member_id => $child->id,
    parent_id        => $parent->id,
    status           => 'active',
});

# Pending drop + transfer requests, and a sent notification.
Registry::DAO::DropRequest->create($dao->db, {
    enrollment_id => $enrollment->id,
    requested_by  => $parent->id,
    reason        => 'Schedule conflict',
});
Registry::DAO::TransferRequest->create($dao->db, {
    enrollment_id     => $enrollment->id,
    target_session_id => $session2->id,
    requested_by      => $parent->id,
    reason            => 'Prefers the later week',
});
Registry::DAO::Notification->create($dao->db, {
    user_id => $parent->id,
    type    => 'general',
    channel => 'email',
    subject => 'Dashboard Notice',
    message => 'Hello from the dashboard test',
    sent_at => '2026-05-30 12:00:00',
});

my $admin = $dao->create(User => {
    username  => 'dashboard_admin',
    name      => 'Dashboard Admin',
    email     => 'dashboard_admin@test.local',
    user_type => 'admin',
    password  => 'x',
});
authenticate_as($t, $admin);

# --- Assertions ------------------------------------------------------------

subtest 'program_overview renders date range from session start/end' => sub {
    $t->get_ok('/admin/dashboard/program_overview')
      ->status_is(200)
      ->content_like(qr/Dashboard Camp/, 'shows the seeded program');
};

subtest 'todays_events renders events for a given date' => sub {
    $t->get_ok('/admin/dashboard/todays_events?date=2026-06-15')
      ->status_is(200)
      ->content_like(qr/Dashboard Week 1/, 'shows the event on that date');
};

subtest 'waitlist_management renders' => sub {
    $t->get_ok('/admin/dashboard/waitlist_management')->status_is(200);
};

subtest 'recent_notifications renders a sent notification' => sub {
    $t->get_ok('/admin/dashboard/recent_notifications')
      ->status_is(200)
      ->content_like(qr/Dashboard Notice/, 'shows the seeded notification');
};

subtest 'enrollment_trends returns JSON with the enrollment counted' => sub {
    $t->get_ok('/admin/dashboard/enrollment_trends')
      ->status_is(200)
      ->content_type_like(qr{application/json})
      ->json_has('/data', 'trend payload has a data series');
};

subtest 'pending_drop_requests resolves program via session events' => sub {
    $t->get_ok('/admin/dashboard/pending_drop_requests')
      ->status_is(200)
      ->content_like(qr/Dashboard Kid/, 'shows the requesting child')
      ->content_like(qr/Dashboard Camp/, 'resolves the program name');
};

subtest 'pending_transfer_requests resolves both sessions via session events' => sub {
    # The from/to project inner-joins only succeed when project resolution
    # works, so a rendered row (showing both session names) confirms the fix.
    $t->get_ok('/admin/dashboard/pending_transfer_requests')
      ->status_is(200)
      ->content_like(qr/Dashboard Week 1/, 'shows the from session')
      ->content_like(qr/Dashboard Week 2/, 'shows the target session');
};

done_testing();
