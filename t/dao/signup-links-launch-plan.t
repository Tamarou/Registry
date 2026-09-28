# ABOUTME: A tenant that signs up without ever seeing a plan page still lands on the launch plan.
# ABOUTME: A NULL platform_pricing_plan_id silently resolves to the Free plan's 0%, so this link IS the money path.
use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer signatures);
use Test::More import => [qw( done_testing is isnt ok cmp_ok subtest diag )];
defer { done_testing };

use Test::Registry::DB;
use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::PriceOps::RevenueShare qw( platform_launch_fraction revenue_share_fraction_for_tenant );

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
my $db   = $dao->db;

$dao->import_workflows(['workflows/tenant-signup.yml']);

my ($workflow) = Registry::DAO::Workflow->find( $db, { slug => 'tenant-signup' } );
ok $workflow, 'tenant-signup workflow imported';

# The rate the platform advertises, read from the database rather than written
# here as a literal -- a test that hardcodes 2.5% passes on the day someone
# changes the plan and the copy disagrees.
my $launch_fraction = platform_launch_fraction($db);
cmp_ok $launch_fraction, '>', 0, 'the platform sells a non-zero revenue share';

my $launch_plan_id = $db->query(q{
    SELECT id FROM registry.pricing_plans
     WHERE metadata->>'launch_rate' = 'true' AND superseded_at IS NULL
})->hash->{id};

# Walk the depends_on chain, which is what the controller follows when it
# redirects to the next step -- not creation order, which only looks right.
sub step_slugs ($w) {
    my @slugs;
    my $step = $w->first_step($db);
    while ($step) {
        push @slugs, $step->slug;
        ($step) = $step->next_step($db);
    }
    return @slugs;
}

subtest 'the signup flow no longer asks which plan' => sub {
    my @slugs = step_slugs($workflow);
    is scalar( grep { $_ eq 'pricing' } @slugs ), 0,
        'no plan-choice step in the flow'
        or diag "steps: @slugs";
    is $slugs[-1], 'complete', 'complete is still the last step';
    is $slugs[-2], 'review',
        'review is the last page the applicant sees -- its button is the commit point'
        or diag "steps: @slugs";
};

subtest 'a signup with no plan selection is provisioned onto the launch plan' => sub {
    my $slug = "launchplan_$$";

    my $run = Registry::DAO::WorkflowRun->create( $db, {
        workflow_id => $workflow->id,
        data        => {
            name            => 'Launch Plan Studio',
            slug            => $slug,
            subdomain       => $slug,
            billing_email   => "billing_$$\@test.example",
            admin_name      => 'Launch Admin',
            admin_email     => "launchadmin_$$\@test.example",
            admin_username  => "launchadmin_$$",
            admin_user_type => 'admin',
            profile         => { name => 'Launch Plan Studio', slug => $slug },
        },
    } );

    my ($review) = $workflow->get_step( $db, { slug => 'review' } );
    ok $review, 'found the review step';

    $run->process( $db, $review, {} );

    my $row = $db->query(
        'SELECT platform_pricing_plan_id FROM registry.tenants WHERE slug = ?',
        $slug )->hash;
    ok $row, 'the review button provisioned the tenant';

    is $row->{platform_pricing_plan_id}, $launch_plan_id,
        'tenant is linked to the plan the platform sells';

    # The assertion that actually costs money if it fails.
    is revenue_share_fraction_for_tenant( $db, $slug ), $launch_fraction,
        'the charge path resolves the advertised rate for this tenant';
};

$t_db->cleanup_test_database;
