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
        description => 'Tenant signup workflow',
        metadata => { test => 1 }
    });
    
    my $review_step = $dao->create( WorkflowStep => {
        workflow_id => $workflow->id,
        slug => 'review',
        description => 'Review and confirm setup details',
        sort_order => 4,
        class => 'Registry::DAO::WorkflowStep'
    });
    
    # Create test workflow run
    my $run = $dao->create( WorkflowRun => {
        workflow_id => $workflow->id,
        user_id => 1,
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
    ok(-f '/home/perigrin/dev/Registry/templates/tenant-signup/review.html.ep', 'Review template exists');
};