# ABOUTME: Controller tests proving AdminDashboard route actions are callable via Mojolicious dispatch.
# ABOUTME: Guards against the Object::Pad method-signature mismatch that left the dashboard dead (issue #178).
use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Registry;
use Test::Registry::DB;
use Test::Registry::Helpers qw(authenticate_as);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

my $t = Test::Registry::Mojo->new('Registry');

my $admin = $dao->create(User => {
    username  => 'dashboard_admin',
    name      => 'Dashboard Admin',
    email     => 'dashboard_admin@test.local',
    user_type => 'admin',
    password  => 'x',
});
authenticate_as($t, $admin);

# These actions were declared `method foo ($c)`, which dies under Mojolicious
# dispatch ("Too few arguments") because the controller is the implicit
# invocant -- so every admin_dashboard#* route returned 500 before reaching its
# body. These two endpoints execute their body fully on an empty database, so
# they isolate the dispatch fix from data-dependent behaviour: export reaches a
# successful render, and send_bulk_message reaches its input validation. Both
# returned 500 (arity death) before the fix.
#
# Note: program_overview, todays_events, waitlist_management,
# recent_notifications, enrollment_trends, and the pending_*_requests endpoints
# are now dispatchable too, but each has its own separate, pre-existing bug
# (SQL/schema mismatches and a template date bug, e.g. #174/#169/#157) that
# 500s independently of #178. Those are tracked and tested separately.

subtest 'export action dispatches and renders' => sub {
    $t->get_ok('/admin/dashboard/export?type=enrollments&_format=json')
      ->status_is(200, 'export returns 200 (was 500 arity death before #178 fix)');
};

subtest 'send_bulk_message dispatches and validates input' => sub {
    $t->post_ok('/admin/dashboard/send_bulk_message' => form => {})
      ->status_is(400, 'missing fields returns 400 (was 500 arity death before #178 fix)');
};

done_testing();
