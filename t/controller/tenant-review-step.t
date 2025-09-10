use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(defer try);
use Test::More import => [qw( done_testing is ok like is_deeply subtest )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Mojo;

# Set up test data
my $dao = Test::Registry::Fixtures::get_test_db();
my $t = Test::Mojo->new('Registry');

subtest 'Review step basic functionality' => sub {
    # Create test workflow and step
    my $workflow = $dao->create( Workflow => {
        slug => 'tenant-signup',
        name => 'Tenant Signup Workflow',
        description => 'Tenant signup workflow'
    });
    
    my $review_step = $dao->create( WorkflowStep => {
        workflow_id => $workflow->id,
        slug => 'review',
        description => 'Review and confirm setup details'
    });
    
    # Create test workflow run
    my $run = $dao->create( WorkflowRun => {
        workflow_id => $workflow->id,
        data => {
            name => 'Test Organization',
            subdomain => 'test-org',
            billing_email => 'test@example.com',
            admin_name => 'John Doe',
            admin_email => 'john@example.com',
            admin_username => 'johndoe',
        }
    });
    
    ok($workflow, 'Created test workflow');
    ok($review_step, 'Created review step');
    ok($run, 'Created workflow run');
};

subtest 'Review template structure' => sub {
    ok(-f 'templates/tenant-signup/review.html.ep', 'Review template exists');
};