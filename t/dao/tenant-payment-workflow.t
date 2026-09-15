#!/usr/bin/env perl

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;

use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::WorkflowSteps::TenantPayment;
use Registry::DAO::Workflow;
use Registry::DAO::PricingPlan;
use Registry::DAO::WorkflowRun;
use JSON;

my $test_db = Test::Registry::DB->new;
my $dao = $test_db->db;
my $db = $dao->db;

# Create test tenant with schema cloning  
$db->query(q{
    INSERT INTO registry.tenants (id, name, slug, billing_status)
    VALUES ('00000000-0000-4000-8000-000000000001', 'Test Tenant', 'test-tenant', 'active')
});
$db->query("SET search_path TO tenant_00000000_0000_4000_8000_000000000001, registry, public");

# Create test workflow using create method
my $workflow = Registry::DAO::Workflow->create($db, {
    name => 'Test Tenant Payment',
    slug => 'test-tenant-payment',
    description => 'Test workflow for payment step'
});

my $payment_step = Registry::DAO::WorkflowSteps::TenantPayment->create($db, {
    workflow_id => $workflow->id,
    slug => 'payment',
    class => 'Registry::DAO::WorkflowSteps::TenantPayment',
    description => 'Payment step'
});

# A run with no selected_pricing_plan: the Solo/Free fallback the two
# configuration subtests below exercise.
my $no_plan_run = Registry::DAO::WorkflowRun->create($db, {
    workflow_id => $workflow->id,
    data => encode_json({})
});

subtest 'TenantPayment workflow step creation' => sub {
    plan tests => 3;
    
    isa_ok($payment_step, 'Registry::DAO::WorkflowSteps::TenantPayment');
    can_ok($payment_step, qw(process prepare_payment_data get_subscription_config));
    is($payment_step->template, 'tenant-signup/payment', 'Correct template');
};

subtest 'Subscription configuration' => sub {
    plan tests => 6;

    my $config = $payment_step->get_subscription_config($db, $no_plan_run);

    ok($config, 'Configuration returned');
    is($config->{plan_name}, 'Solo', 'Plan name correct');
    is($config->{monthly_amount}, 0, 'Monthly amount is $0 (Solo tier)');
    is($config->{currency}, 'usd', 'Currency is USD');
    is($config->{trial_days}, 0, 'No trial period (Solo is already free)');
    ok($config->{features} && @{$config->{features}} > 0, 'Features list provided');
};

subtest 'Solo tier revenue share percent is plan-driven (Free 0%)' => sub {
    plan tests => 4;

    # The constant must be gone; the rate is now derived from the seeded
    # platform Free plan (the no-plan fallback IS the Free plan, 0%).
    ok( !Registry::DAO::WorkflowSteps::TenantPayment->can('REVENUE_SHARE_PERCENT'),
        'REVENUE_SHARE_PERCENT constant removed from TenantPayment'
    );

    my $config = $payment_step->get_subscription_config($db, $no_plan_run);

    # The no-plan fallback rate comes from the platform Free plan (0%), not 2.5.
    is( $config->{revenue_share_percent}, 0,
        'revenue_share_percent is 0 (from the platform Free plan)'
    );
    isnt( $config->{revenue_share_percent}, 2.5,
        'revenue_share_percent is no longer the hardcoded 2.5'
    );

    # The description must contain the same percentage value so they cannot drift.
    my $pct = $config->{revenue_share_percent};
    like( $config->{description},
        qr/\Q$pct\E%/,
        'description string contains the revenue share percent'
    );
};

subtest 'Payment data preparation' => sub {
    plan tests => 4;
    
    # Create test workflow run using create method
    my $run = Registry::DAO::WorkflowRun->create($db, {
        workflow_id => $workflow->id,
        data => encode_json({
            profile => {
                organization_name => 'Test Organization',
                subdomain => 'test-org',
                billing_email => 'billing@test.org'
            }
        })
    });
    
    my $data = $payment_step->prepare_payment_data($db, $run);
    
    ok($data, 'Payment data prepared');
    ok($data->{billing_summary}, 'Billing summary included');
    is($data->{billing_summary}->{organization_name}, 'Test Organization', 'Organization name correct');
    ok($data->{subscription_config}, 'Subscription config included');
};

subtest 'Initial payment page process' => sub {
    plan tests => 3;
    
    my $run = Registry::DAO::WorkflowRun->create($db, {
        workflow_id => $workflow->id,
        data => encode_json({
            profile => {
                organization_name => 'Test Organization',
                billing_email => 'billing@test.org'
            }
        })
    });
    
    my $result = $payment_step->prepare_payment_data($db, $run);
    
    ok($result, 'Process result returned');
    ok(exists $result->{billing_summary}, 'Billing summary in result');
    ok(!$result->{show_payment_form}, 'Payment form not shown initially');
};

subtest 'Retry logic' => sub {
    plan tests => 4;

    my $run = Registry::DAO::WorkflowRun->create($db, {
        workflow_id => $workflow->id,
        data => {}
    });
    
    is($payment_step->get_retry_count($run), 0, 'Initial retry count is 0');
    
    my $count1 = $payment_step->increment_retry_count($db, $run);
    is($count1, 1, 'First increment returns 1');
    
    my $count2 = $payment_step->increment_retry_count($db, $run);
    is($count2, 2, 'Second increment returns 2');
    
    is($payment_step->max_retries, 3, 'Max retries is 3');
};

subtest 'Validation error handling' => sub {
    plan tests => 2;
    
    # Create run without required profile data
    my $run = Registry::DAO::WorkflowRun->create($db, {
        workflow_id => $workflow->id,
        data => encode_json({})
    });
    
    # Test prepare_payment_data with missing profile data
    my $result = $payment_step->prepare_payment_data($db, $run);
    
    ok($result, 'Result returned even with missing data');
    # Should have default values for missing organization name
    is($result->{billing_summary}->{organization_name}, 'Your Organization', 'Default organization name used');
};

# A plan a signup may actually buy: tenant-scoped, on active offer from the
# platform, and not coming_soon -- the three things offered_platform_plan checks.
sub buyable_plan ( $name, $cents ) {
    my $plan = Registry::DAO::PricingPlan->create( $db, {
        plan_scope => 'tenant', plan_name => $name, plan_type => 'standard',
        pricing_model_type => 'hybrid', amount_cents => $cents, currency => 'USD',
        pricing_configuration => { trial_days => 14, description => "$name plan" },
        metadata => {},
    } );
    my $admin = $db->query(
        q{SELECT user_id FROM registry.tenant_users
           WHERE tenant_id = '00000000-0000-0000-0000-000000000000' LIMIT 1} )->array->[0];
    $db->query(
        q{INSERT INTO registry.pricing_relationships
              (provider_id, consumer_id, pricing_plan_id, status, metadata)
          VALUES ('00000000-0000-0000-0000-000000000000', ?, ?, 'active', '{}'::jsonb)},
        $admin, $plan->id );
    return $plan;
}

subtest 'Subscription config follows the run in hand, not the newest run' => sub {
    plan tests => 4;

    # Two genuinely buyable plans. The blob in run data used to carry
    # plan_name and amount_cents and was used verbatim; since #347 it carries
    # an id and the row is re-read, so these have to be real offers -- a
    # tenant-scoped plan with an active platform relationship, not coming_soon.
    # The seeded Studio and Empire tiers are coming_soon and would rightly be
    # refused, so they cannot stand in here.
    my $mine_plan  = buyable_plan( 'Studio Test Tier', 4900 );
    my $their_plan = buyable_plan( 'Empire Test Tier', 19900 );

    my $mine = Registry::DAO::WorkflowRun->create($db, {
        workflow_id => $workflow->id,
        data => encode_json({
            profile => {
                organization_name => 'My Organization',
                billing_email     => 'me@example.org',
            },
            selected_pricing_plan => { id => $mine_plan->id },
        })
    });

    # Another visitor starts a signup after mine and picks a different plan.
    my $theirs = Registry::DAO::WorkflowRun->create($db, {
        workflow_id => $workflow->id,
        data => encode_json({
            selected_pricing_plan => { id => $their_plan->id },
        })
    });

    # latest_run orders by created_at, and two rows written in the same instant
    # would tie; make theirs unambiguously the newest.
    $db->query(
        q{UPDATE workflow_runs SET created_at = created_at + interval '1 minute' WHERE id = ?},
        $theirs->id
    );

    my $data = $payment_step->prepare_payment_data($db, $mine);
    is($data->{subscription_config}{plan_name}, 'Studio Test Tier',
        'payment page prices my run with my plan');
    is($data->{subscription_config}{monthly_amount}, 4900,
        'and with my amount');
    is($data->{billing_summary}{plan_details}{plan_name}, 'Studio Test Tier',
        'billing summary agrees');

    my $config = eval { $payment_step->get_subscription_config($db, $mine) };
    is(($config ? $config->{plan_name} : undef), 'Studio Test Tier',
        'get_subscription_config prices the run it is handed');
};

done_testing();