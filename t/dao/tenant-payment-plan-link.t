# ABOUTME: Verifies TenantPayment quotes the preselected Solo version before any choice is carried,
# ABOUTME: and grants the platform offer the run carries at signup.
use 5.42.0;
use lib qw(lib t/lib);
use Test::More;

use Test::Registry::DB;
use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::DAO::WorkflowSteps::TenantPayment;
use Registry::PriceOps::PlatformTerms qw( platform_entitlement_terms );
use Registry::DAO::User;

my $test_db = Test::Registry::DB->new;
my $dao = $test_db->db;
my $db  = $dao->db;

# Minimal workflow + TenantPayment step to drive provisioning.
my $workflow = Registry::DAO::Workflow->create($db, {
    name        => 'Plan Link Test',
    slug        => "plan-link-$$",
    description => 'Test workflow for plan-link persistence',
});

my $step = Registry::DAO::WorkflowSteps::TenantPayment->create($db, {
    workflow_id => $workflow->id,
    slug        => 'payment',
    class       => 'Registry::DAO::WorkflowSteps::TenantPayment',
    description => 'Payment step',
});

subtest 'a run with no choice yet quotes the preselected Solo version' => sub {
    plan tests => 3;

    my $run = Registry::DAO::WorkflowRun->create($db, {
        workflow_id => $workflow->id,
        data        => { profile => { organization_name => 'NoPlan Org' } },
    });

    my $config = $step->get_subscription_config($db, $run);
    is $config->{offer_version_id}, '00000000-0000-0000-0003-000000000001', 'Solo v1 is quoted';
    is $config->{plan_name}, 'Solo', 'by its offer name';
    is $config->{revenue_share_percent}, 2.5,
        'at its own rate, not the Free plan 0%';
};

subtest 'provisioning grants the published platform offer' => sub {
    plan tests => 3;

    my $slug = "planlink_tenant_$$";
    my $run = Registry::DAO::WorkflowRun->create($db, {
        workflow_id => $workflow->id,
        data        => {
            profile               => { name => 'Plan Link Tenant', slug => $slug },
            slug                  => $slug,
            name                  => 'Plan Link Tenant',
            admin_name            => 'Plan Admin',
            admin_email           => "planadmin_$$\@test.example",
            admin_username        => "planadmin_$$",
            admin_user_type       => 'admin',
            selected_offer_version => '00000000-0000-0000-0003-000000000001',
        },
    });

    my $result = $step->_provision_tenant($db, $run);
    ok $result->{tenant}, 'tenant provisioned';

    my $terms = platform_entitlement_terms( $db, $slug );
    is $terms->{id}, '00000000-0000-0000-0003-000000000001',
        'tenant holds an entitlement to Solo v1, the published platform offer';
    cmp_ok $terms->{fraction}, '==', 0.025, 'under its 2.5% revenue share';
};

$test_db->cleanup_test_database;
done_testing;
