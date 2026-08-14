# ABOUTME: Verifies TenantPayment persists the tenant -> platform plan link at signup
# ABOUTME: and that the no-plan get_subscription_config rate is plan-driven (Free 0%), not hardcoded.
use 5.42.0;
use lib qw(lib t/lib);
use Test::More;

use Test::Registry::DB;
use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::DAO::WorkflowSteps::TenantPayment;
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

# Resolve the seeded 2% revenue-share plan to select during signup.
my $selected_plan = $db->query(q{
    SELECT id, plan_name, amount_cents, currency, pricing_configuration
      FROM registry.pricing_plans
     WHERE plan_scope = 'tenant'
       AND pricing_model_type = 'percentage'
       AND metadata->>'default' IS DISTINCT FROM 'true'
     ORDER BY created_at
     LIMIT 1
})->hash;
ok $selected_plan, 'seeded 2% revenue-share plan found';

subtest 'no-plan get_subscription_config is plan-driven (Free 0%)' => sub {
    plan tests => 2;

    # Fresh run with no selected_pricing_plan -> Free fallback.
    my $run = Registry::DAO::WorkflowRun->create($db, {
        workflow_id => $workflow->id,
        data        => { profile => { organization_name => 'NoPlan Org' } },
    });

    my $config = $step->get_subscription_config($db);
    is $config->{revenue_share_percent}, 0,
        'revenue_share_percent is 0 (from the platform Free plan)';
    like $config->{description}, qr/\b0%/,
        'description reflects the plan-driven 0% rate';
};

subtest 'provisioning persists the selected plan link' => sub {
    plan tests => 2;

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
            subscription          => {
                stripe_subscription_id => 'sub_test_' . time(),
                trial_ends_at          => time() + (30 * 24 * 60 * 60),
                status                 => 'trialing',
            },
            selected_pricing_plan => {
                id            => $selected_plan->{id},
                plan_name     => $selected_plan->{plan_name},
                amount_cents  => $selected_plan->{amount_cents},
                currency      => $selected_plan->{currency},
            },
        },
    });

    my $result = $step->_provision_tenant($db, $run);
    ok $result->{tenant}, 'tenant provisioned';

    my $row = $db->query(
        'SELECT platform_pricing_plan_id FROM registry.tenants WHERE slug = ?',
        $slug,
    )->hash;
    is $row->{platform_pricing_plan_id}, $selected_plan->{id},
        'tenant row links to the selected platform pricing plan';
};

$test_db->cleanup_test_database;
done_testing;
