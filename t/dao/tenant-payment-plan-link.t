# ABOUTME: Verifies TenantPayment persists the tenant -> platform plan link at signup
# ABOUTME: including when nobody chose a plan, which is now every signup.
use 5.42.0;
use lib qw(lib t/lib);
use Test::More;

use Test::Registry::DB;
use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::DAO::WorkflowSteps::TenantPayment;
use Registry::PriceOps::RevenueShare ();
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

subtest 'a run with no plan selection resolves the launch plan' => sub {
    plan tests => 3;

    my $run = Registry::DAO::WorkflowRun->create($db, {
        workflow_id => $workflow->id,
        data        => { profile => { organization_name => 'NoPlan Org' } },
    });

    my $plan = $step->resolve_selected_plan($db, $run);
    ok $plan, 'a plan resolves even though nothing was selected';
    is $plan->id, Registry::PriceOps::RevenueShare::platform_launch_plan_id($db),
        'and it is the plan the platform sells';

    my $config = $step->get_subscription_config($db, $run);
    is $config->{revenue_share_percent},
        Registry::PriceOps::RevenueShare::platform_launch_fraction($db) * 100,
        'the quoted rate is that plan rate, not the Free plan 0%';
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
