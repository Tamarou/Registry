#!/usr/bin/env perl
use v5.34.0;
use warnings;
use experimental 'signatures';
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::PricingPlan;
use Registry::DAO::PricingRelationship;
use Registry::DAO::WorkflowSteps::PricingPlanSelection;
use Registry::DAO::WorkflowSteps::TenantPayment;

my $test_db = Test::Registry::DB->new;
my $dao = $test_db->db;

# Create platform tenant pricing plans in registry schema
my $platform_uuid = '00000000-0000-0000-0000-000000000000';

subtest 'Integration test setup' => sub {
    # Create platform user for pricing relationships
    my $platform_user_id = $dao->db->query('SELECT gen_random_uuid()')->array->[0];

    $dao->db->query(q{
        INSERT INTO registry.users (id, username, passhash, user_type)
        VALUES (?, ?, ?, ?)
    }, $platform_user_id, 'platform_admin', '$2b$12$DummyHashForSystemUser', 'admin');

    $dao->db->query(q{
        INSERT INTO registry.user_profiles (user_id, email, name)
        VALUES (?, ?, ?)
    }, $platform_user_id, 'admin@registry.platform', 'Platform Admin');

    $dao->db->query(q{
        INSERT INTO registry.tenant_users (tenant_id, user_id, is_primary)
        VALUES (?, ?, ?)
    }, $platform_uuid, $platform_user_id, 1);

    # Create enterprise pricing plan
    my $enterprise_plan = Registry::DAO::PricingPlan->create($dao->db, {
        plan_name => 'Registry Enterprise',
        plan_type => 'standard',
        plan_scope => 'tenant',
        pricing_model_type => 'fixed',
        amount => 50000,  # $500.00 in cents
        currency => 'USD',
        pricing_configuration => {
            trial_days => 30,
            billing_cycle => 'monthly',
            description => 'Advanced features for large organizations',
            features => [
                'Everything in Professional',
                'Advanced analytics and reporting',
                'White-label customization',
                'Priority support'
            ]
        },
        metadata => {
            display_order => 1,
            suitable_for => 'large_programs'
        }
    });

    # Create pricing relationship
    Registry::DAO::PricingRelationship->create($dao->db, {
        provider_id => $platform_uuid,
        consumer_id => $platform_user_id,
        pricing_plan_id => $enterprise_plan->id,
        status => 'active',
        metadata => { plan_type => 'tenant_subscription' }
    });

    ok $enterprise_plan->id, 'Enterprise plan created';
};

subtest 'Full tenant signup integration test' => sub {
    # Create tenant signup workflow
    my $workflow = Registry::DAO::Workflow->create($dao->db, {
        name => 'Integration Test Tenant Signup',
        slug => 'integration-test-tenant-signup',
        description => 'Test workflow for full pricing plan selection integration'
    });

    # Add pricing plan selection step
    my $pricing_step = Registry::DAO::WorkflowStep->create($dao->db, {
        workflow_id => $workflow->id,
        slug => 'pricing',
        class => 'Registry::DAO::WorkflowSteps::PricingPlanSelection',
        description => 'Select pricing plan'
    });

    # Add payment step that depends on pricing
    my $payment_step = Registry::DAO::WorkflowStep->create($dao->db, {
        workflow_id => $workflow->id,
        slug => 'payment',
        class => 'Registry::DAO::WorkflowSteps::TenantPayment',
        description => 'Payment processing',
        depends_on => $pricing_step->id
    });

    # Set first step
    $workflow->update($dao->db, { first_step => 'pricing' });

    # Create a workflow run
    my $run = $workflow->new_run($dao->db);

    # Set up initial workflow data (as if coming from previous steps)
    $run->update_data($dao->db, {
        name => 'Test Enterprise Organization',
        admin_email => 'admin@enterprise.test',
        billing_email => 'billing@enterprise.test'
    });

    # Step 1: Test pricing plan selection
    my $pricing_step_obj = $workflow->get_step($dao->db, { slug => 'pricing' });

    # Get available plans
    my $pricing_result = $pricing_step_obj->process($dao->db, {});
    ok $pricing_result->{data}->{pricing_plans}, 'Pricing plans available';
    is scalar(@{$pricing_result->{data}->{pricing_plans}}), 1, 'One pricing plan available';

    my $enterprise_plan = $pricing_result->{data}->{pricing_plans}->[0];
    is $enterprise_plan->{plan_name}, 'Registry Enterprise', 'Enterprise plan available';
    is $enterprise_plan->{amount}, 50000, 'Plan amount correct';

    # Select the enterprise plan
    my $selection_result = $pricing_step_obj->process($dao->db, {
        selected_plan_id => $enterprise_plan->{id}
    });

    ok !$selection_result->{errors}, 'No errors when selecting plan';
    isnt $selection_result->{next_step}, $pricing_step->id, 'Moves to next step after selection';

    # Verify plan was stored in workflow data
    my $updated_run = $workflow->latest_run($dao->db);
    my $stored_plan = $updated_run->data->{selected_pricing_plan};

    ok $stored_plan, 'Pricing plan stored in workflow data';
    is $stored_plan->{plan_name}, 'Registry Enterprise', 'Correct plan name stored';
    is $stored_plan->{amount}, 50000, 'Correct amount stored';

    # Step 2: Test payment step uses selected plan
    my $payment_step_obj = $workflow->get_step($dao->db, { slug => 'payment' });

    # Get payment configuration
    my $payment_config = $payment_step_obj->get_subscription_config($dao->db);

    is $payment_config->{plan_name}, 'Registry Enterprise', 'Payment uses selected plan name';
    is $payment_config->{monthly_amount}, 50000, 'Payment uses selected plan amount';
    is $payment_config->{trial_days}, 30, 'Payment uses selected plan trial days';
    is $payment_config->{formatted_price}, '$500/month', 'Payment formats price correctly';
    like $payment_config->{description}, qr/Advanced features/, 'Payment uses selected plan description';

    # Test payment data preparation
    my $payment_data = $payment_step_obj->prepare_payment_data($dao->db, $updated_run);

    ok $payment_data->{billing_summary}, 'Billing summary prepared';
    is $payment_data->{billing_summary}->{organization_name}, 'Test Enterprise Organization', 'Organization name correct';
    is $payment_data->{billing_summary}->{plan_details}->{plan_name}, 'Registry Enterprise', 'Plan details use selected plan';
    is $payment_data->{billing_summary}->{plan_details}->{formatted_price}, '$500/month', 'Plan price formatted correctly';
};

subtest 'Backwards compatibility test' => sub {
    # Create workflow without pricing plan selection step
    my $legacy_workflow = Registry::DAO::Workflow->create($dao->db, {
        name => 'Legacy Tenant Signup',
        slug => 'legacy-tenant-signup',
        description => 'Test workflow for backwards compatibility'
    });

    my $legacy_payment_step = Registry::DAO::WorkflowStep->create($dao->db, {
        workflow_id => $legacy_workflow->id,
        slug => 'payment',
        class => 'Registry::DAO::WorkflowSteps::TenantPayment',
        description => 'Payment processing'
    });

    $legacy_workflow->update($dao->db, { first_step => 'payment' });

    # Create run without pricing plan data
    my $legacy_run = $legacy_workflow->new_run($dao->db);
    $legacy_run->update_data($dao->db, {
        name => 'Legacy Organization',
        admin_email => 'admin@legacy.test'
    });

    # Test that payment step falls back to default configuration
    my $legacy_payment_obj = $legacy_workflow->get_step($dao->db, { slug => 'payment' });
    my $legacy_config = $legacy_payment_obj->get_subscription_config($dao->db);

    is $legacy_config->{plan_name}, 'Registry Professional', 'Falls back to default plan name';
    is $legacy_config->{monthly_amount}, 20000, 'Falls back to default amount';
    is $legacy_config->{formatted_price}, '$200.00/month', 'Falls back to default price format';

    ok 1, 'Backwards compatibility maintained';
};

done_testing;