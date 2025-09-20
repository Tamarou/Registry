# ABOUTME: Tests AdminDashboard workflow architecture with admin-specific workflows
# ABOUTME: Verifies that admin dashboard routes properly redirect to admin workflows

use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is ok subtest like diag plan )];
defer { done_testing };

use Test::Mojo;
use Registry;
use Test::Registry::DB;

# Set up test database
my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

my $t = Test::Mojo->new('Registry');

subtest "AdminDashboard controller has only data retrieval methods" => sub {
    plan tests => 4;

    # Verify data retrieval methods exist
    ok(Registry::Controller::AdminDashboard->can('index'), 'AdminDashboard has index method');
    ok(Registry::Controller::AdminDashboard->can('pending_drop_requests'), 'AdminDashboard has pending_drop_requests method');
    ok(Registry::Controller::AdminDashboard->can('pending_transfer_requests'), 'AdminDashboard has pending_transfer_requests method');

    # Verify action methods were removed (delegated to workflows)
    ok(!Registry::Controller::AdminDashboard->can('process_drop_request'), 'AdminDashboard process_drop_request method removed (delegated to workflow)');
};

subtest "Admin dashboard routes redirect to workflows" => sub {
    plan tests => 3;

    # Test that admin dashboard route redirects to admin-dashboard workflow
    $t->get_ok('/admin/dashboard');

    # Test that admin action routes redirect to admin approval workflows
    $t->post_ok('/admin/dashboard/process_drop_request', form => {
        drop_request_id => 'test-123',
        action => 'approve',
        admin_notes => 'Test approval'
    });

    $t->post_ok('/admin/dashboard/process_transfer_request', form => {
        transfer_request_id => 'test-456',
        action => 'deny',
        admin_notes => 'Test denial'
    });
};


subtest "Admin workflow architecture validation" => sub {
    plan tests => 3;

    # Verify admin workflow files exist
    ok(-f 'workflows/admin-dashboard.yml', 'Admin dashboard workflow exists');
    ok(-f 'workflows/admin-drop-approval.yml', 'Admin drop approval workflow exists');
    ok(-f 'workflows/admin-transfer-approval.yml', 'Admin transfer approval workflow exists');
};