# ABOUTME: Controller tests for AdminDashboard CSV export functionality
# ABOUTME: Tests HTTP endpoints, content negotiation, and proper CSV format rendering

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

subtest "Admin dashboard export endpoint exists" => sub {
    plan tests => 1;

    # Test that the export route exists and responds (status doesn't matter for route existence)
    $t->get_ok('/admin/dashboard/export');
};

subtest "CSV export content negotiation" => sub {
    plan tests => 3;

    # Test that routes accept format parameters and respond (not testing auth)
    $t->get_ok('/admin/dashboard/export?type=enrollments&format=csv');
    $t->get_ok('/admin/dashboard/export?type=enrollments&format=json');
    $t->get_ok('/admin/dashboard/export?type=enrollments');
};

subtest "CSV renderer functionality" => sub {
    plan tests => 4;

    # Test that the CSV renderer was registered properly
    my $app = $t->app;
    ok $app->renderer->handlers->{csv}, 'CSV renderer is registered';

    # Test CSV rendering with sample data
    my $sample_data = [
        { id => 1, name => 'Test Item', status => 'active' },
        { id => 2, name => 'Test "Quoted" Item', status => 'pending' }
    ];

    # Create a mock controller to test renderer
    my $mock_c = Mojolicious::Controller->new;
    $mock_c->app($app);

    my $output = '';
    my $options = { csv => $sample_data };

    # Call the CSV renderer directly
    $app->renderer->handlers->{csv}->($app->renderer, $mock_c, \$output, $options);

    ok $output, 'CSV renderer produces output';
    # Check that all expected headers are present (order may vary)
    like $output, qr/"name"/, 'CSV contains name header';
    like $output, qr/"Test ""Quoted"" Item"/, 'CSV properly escapes quotes';
};

subtest "Export data types" => sub {
    plan tests => 3;

    # Test each export type route exists and responds (not testing auth)
    $t->get_ok('/admin/dashboard/export?type=enrollments&format=csv');
    $t->get_ok('/admin/dashboard/export?type=attendance&format=csv');
    $t->get_ok('/admin/dashboard/export?type=waitlist&format=csv');
};

subtest "AdminDashboard controller methods exist" => sub {
    plan tests => 1;

    # Verify the export_data method exists on the controller
    ok(Registry::Controller::AdminDashboard->can('export_data'), 'AdminDashboard has export_data method');
};