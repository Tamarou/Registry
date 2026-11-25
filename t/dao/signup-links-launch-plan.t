# ABOUTME: A tenant that signs up on the review page's preselected Solo holds the platform's published offer.
# ABOUTME: Absence is not zero: that entitlement IS the money path, so its rate must be the advertised one.
use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer signatures);
use Test::More import => [qw( done_testing is isnt like ok cmp_ok subtest diag )];
defer { done_testing };

use Test::Registry::DB;
use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::DAO::Tenant;
use Registry::PriceOps::RevenueShare qw( platform_offered_fraction );
use Registry::PriceOps::PlatformTerms qw( platform_entitlement_terms );

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
my $db   = $dao->db;

$dao->import_workflows(['workflows/tenant-signup.yml']);

my ($workflow) = Registry::DAO::Workflow->find( $db, { slug => 'tenant-signup' } );
ok $workflow, 'tenant-signup workflow imported';

# The rate the platform advertises, read from the database rather than written
# here as a literal -- a test that hardcodes 2.5% passes on the day someone
# changes the plan and the copy disagrees.
my $launch_fraction = platform_offered_fraction($db);
cmp_ok $launch_fraction, '>', 0, 'the platform sells a non-zero revenue share';

# The bootstrap seed's fixed id for Solo v1, the platform's offer to tenants.
my $SOLO_V1 = '00000000-0000-0000-0003-000000000001';

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

subtest 'a signup on the preselected Solo is granted the published platform offer' => sub {
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

    $run->process( $db, $review, { offer_version => $SOLO_V1 } );

    ok $db->query( 'SELECT 1 FROM registry.tenants WHERE slug = ?', $slug )->hash,
        'the review button provisioned the tenant';

    my $terms = platform_entitlement_terms( $db, $slug );
    is $terms->{id}, $SOLO_V1, 'tenant holds an entitlement to the offer the platform sells';

    # The assertion that actually costs money if it fails.
    cmp_ok $terms->{fraction}, '==', $launch_fraction,
        'the entitlement carries the advertised rate for this tenant';
};

subtest 'the subdomain the applicant is shown is the one they get' => sub {
    # Three derivations used to disagree: the profile page previewed
    # clay-kiln-studio, told the applicant it was available, and provisioning
    # produced clay_&_kiln_studio -- a schema name and a hostname with an
    # ampersand in it, which the tenant router's /\A[a-z][a-z0-9_]{0,62}\z/
    # could never have matched.
    my $name = 'Clay & Kiln Studio';

    my $previewed = Registry::DAO::Tenant->available_slug_for_name( $db, $name );
    like $previewed, qr/\A[a-z][a-z0-9_]{0,62}\z/,
        'the previewed slug is one the tenant router can route';

    my $run = Registry::DAO::WorkflowRun->create( $db, {
        workflow_id => $workflow->id,
        data        => {
            name            => $name,
            admin_name      => 'Sam Potter',
            admin_email     => "sam_$$\@test.example",
            admin_username  => "sam_$$",
            admin_user_type => 'admin',
        },
    } );

    my ($review) = $workflow->get_step( $db, { slug => 'review' } );

    my $shown = $review->prepare_template_data( $db, $run )->{profile}{subdomain};
    is $shown, $previewed, 'the review page shows that same slug';

    $run->process( $db, $review, { offer_version => $SOLO_V1 } );
    is $run->data->{subdomain}, $previewed,
        'and provisioning uses it rather than deriving a different one';
};

$t_db->cleanup_test_database;
