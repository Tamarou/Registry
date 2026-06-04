# ABOUTME: Regression tests that dashboard widgets rendering DateTime->from_epoch survive real timestamp data.
# ABOUTME: Postgres returns timestamp columns as strings; queries must EXTRACT(EPOCH) so templates do not 500 (#217).
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
use Registry::DAO::Waitlist;
use Registry::DAO::Message;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

my $t = Test::Registry::Mojo->new('Registry');
# Pin the controller's dao() to the seeded test schema regardless of tenant.
$t->app->helper(dao => sub { $dao });

# A second client used for the parent dashboard; authenticate_as pins the
# first user it sees for the life of the app instance, so the parent needs
# its own client distinct from the admin's.
my $tp = Test::Registry::Mojo->new('Registry');
$tp->app->helper(dao => sub { $dao });

# --- Seed an enrollment chain plus an OFFERED waitlist entry --------------
my $location = $dao->create(Location => {
    name => 'Timestamp Studio', slug => 'timestamp-studio',
    address_info => { street => '1 Main', city => 'Orlando', state => 'FL' },
    metadata => {},
});
my $program = $dao->create(Project => {
    status => 'published', name => 'Timestamp Camp',
    program_type_slug => 'summer-camp', metadata => {},
});
my $teacher = $dao->create(User => { username => 'ts_teacher', user_type => 'staff' });
my $session = $dao->create(Session => {
    name => 'Timestamp Week 1', start_date => '2026-01-01', end_date => '2026-12-31',
    status => 'published', capacity => 16, metadata => {},
});
my $event = $dao->create(Event => {
    time => '2026-06-15 09:00:00', duration => 420,
    location_id => $location->id, project_id => $program->id,
    teacher_id => $teacher->id, capacity => 16, metadata => {},
});
$session->add_events($dao->db, $event->id);

my $parent = $dao->create(User => {
    username => 'ts_parent', name => 'Timestamp Parent',
    user_type => 'parent', email => 'ts@example.com',
});
my $child = Registry::DAO::Family->add_child($dao->db, $parent->id, {
    child_name => 'Timestamp Kid', birth_date => '2018-01-01', grade => '3',
    medical_info => {}, emergency_contact => { name => 'P', phone => '555' },
});

# A waitlist entry that has been offered, so the template renders its
# expires_at via DateTime->from_epoch. This is the column that comes back
# from Postgres as a timestamp string and triggers the 500 (#217).
my $entry = Registry::DAO::Waitlist->create($dao->db, {
    session_id       => $session->id,
    location_id      => $location->id,
    student_id       => $child->id,
    family_member_id => $child->id,
    parent_id        => $parent->id,
    status           => 'waiting',
    position         => 1,
});
$dao->db->query(
    q{UPDATE waitlist SET status = 'offered',
        offered_at = NOW(),
        expires_at = NOW() + INTERVAL '12 hours'
      WHERE id = ?},
    $entry->id,
);

# A sent message so the parent dashboard renders sent_at via from_epoch.
my $message = Registry::DAO::Message->send_message($dao->db, {
    sender_id    => $teacher->id,
    subject      => 'Timestamp Notice',
    body         => 'Hello from the timestamp test',
    message_type => 'announcement',
    scope        => 'tenant-wide',
    scope_id     => undef,
}, [ $parent->id ], send_now => 1);

# --- Admin assertions ------------------------------------------------------

my $admin = $dao->create(User => {
    username  => 'timestamp_admin',
    name      => 'Timestamp Admin',
    email     => 'timestamp_admin@test.local',
    user_type => 'admin',
    password  => 'x',
});
authenticate_as($t, $admin);

subtest 'admin waitlist_management renders an offered entry (expires_at)' => sub {
    $t->get_ok('/admin/dashboard/waitlist_management?status=all')
      ->status_is(200)
      ->content_like(qr/Timestamp Kid/, 'shows the offered child')
      ->content_like(qr/Expires/, 'rendered the expires_at line via from_epoch');
};

# --- Parent assertions -----------------------------------------------------

authenticate_as($tp, $parent);

subtest 'parent dashboard renders recent message (sent_at)' => sub {
    $tp->get_ok('/parent/dashboard')
      ->status_is(200)
      ->content_like(qr/Timestamp Notice/, 'shows the sent message');
};

done_testing();
