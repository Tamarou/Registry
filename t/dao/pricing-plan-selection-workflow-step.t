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

my $test_db = Test::Registry::DB->new;
my $dao = $test_db->db;

# Create platform tenant pricing plans in registry schema
my $platform_uuid = '00000000-0000-0000-0000-000000000000';

subtest 'Test data setup' => sub {
    # First create a system user for the platform tenant
    # The platform tenant should already exist from migrations
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

    # Create test pricing plans for the platform tenant
    my $basic_plan = Registry::DAO::PricingPlan->create($dao->db, {
        plan_name => 'Registry Basic',
        plan_type => 'standard',
        plan_scope => 'tenant',
        pricing_model_type => 'fixed',
        amount => 10000,  # $100.00 in cents
        currency => 'USD',
        pricing_configuration => {
            trial_days => 14,
            billing_cycle => 'monthly',
            description => 'Perfect for small programs',
            features => [
                'Up to 50 student enrollments',
                'Basic attendance tracking',
                'Email support'
            ]
        },
        metadata => {
            display_order => 1,
            suitable_for => 'small_programs'
        }
    });

    my $professional_plan = Registry::DAO::PricingPlan->create($dao->db, {
        plan_name => 'Registry Professional',
        plan_type => 'standard',
        plan_scope => 'tenant',
        pricing_model_type => 'fixed',
        amount => 20000,  # $200.00 in cents
        currency => 'USD',
        pricing_configuration => {
            trial_days => 30,
            billing_cycle => 'monthly',
            description => 'Complete after-school program management solution',
            features => [
                'Unlimited student enrollments',
                'Attendance tracking and reporting',
                'Parent communication tools',
                'Payment processing',
                'Waitlist management',
                'Staff scheduling',
                'Custom reporting'
            ]
        },
        metadata => {
            display_order => 2,
            suitable_for => 'medium_programs'
        }
    });

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
                'Priority support',
                'Custom integrations',
                'Multi-location management'
            ]
        },
        metadata => {
            display_order => 3,
            suitable_for => 'large_programs'
        }
    });

    # Create pricing relationships to link plans to platform tenant
    Registry::DAO::PricingRelationship->create($dao->db, {
        provider_id => $platform_uuid,
        consumer_id => $platform_user_id,  # Use platform user as consumer
        pricing_plan_id => $basic_plan->id,
        status => 'active',
        metadata => { plan_type => 'tenant_subscription' }
    });

    Registry::DAO::PricingRelationship->create($dao->db, {
        provider_id => $platform_uuid,
        consumer_id => $platform_user_id,
        pricing_plan_id => $professional_plan->id,
        status => 'active',
        metadata => { plan_type => 'tenant_subscription' }
    });

    Registry::DAO::PricingRelationship->create($dao->db, {
        provider_id => $platform_uuid,
        consumer_id => $platform_user_id,
        pricing_plan_id => $enterprise_plan->id,
        status => 'active',
        metadata => { plan_type => 'tenant_subscription' }
    });

    ok $basic_plan->id, 'Basic plan created';
    ok $professional_plan->id, 'Professional plan created';
    ok $enterprise_plan->id, 'Enterprise plan created';
};

subtest 'Create workflow with pricing plan selection step' => sub {
    # Create tenant signup workflow
    my $workflow = Registry::DAO::Workflow->create($dao->db, {
        name => 'Test Tenant Signup',
        slug => 'test-tenant-signup',
        description => 'Test workflow for tenant signup with pricing plan selection'
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

    ok $workflow->id, 'Workflow created';
    ok $pricing_step->id, 'Pricing plan selection step created';
    ok $payment_step->id, 'Payment step created';
};

subtest 'PricingPlanSelection step functionality' => sub {
    my $workflow = Registry::DAO::Workflow->find($dao->db, { slug => 'test-tenant-signup' });
    my $run = $workflow->new_run($dao->db);

    # Set up minimal workflow data
    $run->update_data($dao->db, {
        name => 'Test Organization',
        admin_email => 'admin@test.org'
    });

    my $pricing_step = $workflow->get_step($dao->db, { slug => 'pricing' });

    # Test initial page load (no form data)
    my $result = $pricing_step->process($dao->db, {});

    is $result->{next_step}, $pricing_step->id, 'Stays on pricing step initially';
    ok $result->{data}, 'Data prepared for template';
    ok $result->{data}->{pricing_plans}, 'Pricing plans available';
    is scalar(@{$result->{data}->{pricing_plans}}), 3, 'Three pricing plans available';

    # Verify plans are ordered correctly
    my $plans = $result->{data}->{pricing_plans};
    is $plans->[0]->{plan_name}, 'Registry Basic', 'First plan is Basic';
    is $plans->[1]->{plan_name}, 'Registry Professional', 'Second plan is Professional';
    is $plans->[2]->{plan_name}, 'Registry Enterprise', 'Third plan is Enterprise';

    # Verify plan data structure
    my $basic_plan = $plans->[0];
    ok $basic_plan->{id}, 'Plan has ID';
    is $basic_plan->{amount}, 10000, 'Plan amount correct';
    is $basic_plan->{currency}, 'USD', 'Plan currency correct';
    ok $basic_plan->{pricing_configuration}, 'Plan has pricing configuration';
    ok $basic_plan->{pricing_configuration}->{features}, 'Plan has features list';
    like $basic_plan->{pricing_configuration}->{description}, qr/small programs/, 'Plan has description';
};

subtest 'Plan selection processing' => sub {
    my $workflow = Registry::DAO::Workflow->find($dao->db, { slug => 'test-tenant-signup' });
    my $run = $workflow->new_run($dao->db);

    # Set up workflow data
    $run->update_data($dao->db, {
        name => 'Test Organization',
        admin_email => 'admin@test.org'
    });

    my $pricing_step = $workflow->get_step($dao->db, { slug => 'pricing' });

    # Get available plans to select from
    my $initial_result = $pricing_step->process($dao->db, {});
    my $plans = $initial_result->{data}->{pricing_plans};
    my $professional_plan = $plans->[1];  # Professional plan

    # Test plan selection
    my $result = $pricing_step->process($dao->db, {
        selected_plan_id => $professional_plan->{id}
    });

    ok !$result->{errors}, 'No errors when selecting valid plan';
    isnt $result->{next_step}, $pricing_step->id, 'Moves to next step after selection';

    # Verify plan was stored in workflow data
    my $updated_run = $workflow->latest_run($dao->db);
    my $stored_plan = $updated_run->data->{selected_pricing_plan};

    ok $stored_plan, 'Pricing plan stored in workflow data';
    is $stored_plan->{id}, $professional_plan->{id}, 'Correct plan ID stored';
    is $stored_plan->{plan_name}, 'Registry Professional', 'Correct plan name stored';
    is $stored_plan->{amount}, 20000, 'Correct amount stored';
    ok $stored_plan->{pricing_configuration}, 'Pricing configuration stored';
};

subtest 'Error handling' => sub {
    my $workflow = Registry::DAO::Workflow->find($dao->db, { slug => 'test-tenant-signup' });
    my $run = $workflow->new_run($dao->db);

    my $pricing_step = $workflow->get_step($dao->db, { slug => 'pricing' });

    # Test missing plan selection (should show pricing page, not error)
    my $result = $pricing_step->process($dao->db, {});

    ok !$result->{errors}, 'No errors when no plan data submitted';
    is $result->{next_step}, $pricing_step->id, 'Stays on pricing step for initial page load';

    # Test empty plan selection
    $result = $pricing_step->process($dao->db, {
        selected_plan_id => ''
    });

    ok $result->{errors}, 'Error when empty plan selected';
    like $result->{errors}->[0], qr/please select/i, 'Appropriate error message';
    is $result->{next_step}, $pricing_step->id, 'Stays on pricing step';

    # Test invalid plan ID
    $result = $pricing_step->process($dao->db, {
        selected_plan_id => 'invalid-plan-id'
    });

    ok $result->{errors}, 'Error when invalid plan selected';
    like $result->{errors}->[0], qr/not available/i, 'Appropriate error message for invalid plan';
    is $result->{next_step}, $pricing_step->id, 'Stays on pricing step';

    # Test plan that exists but isn't active for platform
    my $inactive_plan = Registry::DAO::PricingPlan->create($dao->db, {
        plan_name => 'Inactive Plan',
        plan_type => 'standard',
        plan_scope => 'tenant',
        amount => 15000,
        currency => 'USD',
        pricing_configuration => { trial_days => 14 }
    });

    # Don't create a pricing relationship for this plan

    $result = $pricing_step->process($dao->db, {
        selected_plan_id => $inactive_plan->id
    });

    ok $result->{errors}, 'Error when plan not available for platform';
    like $result->{errors}->[0], qr/not available/i, 'Appropriate error message for unavailable plan';
};

subtest 'Template method' => sub {
    my $workflow = Registry::DAO::Workflow->find($dao->db, { slug => 'test-tenant-signup' });
    my $pricing_step = $workflow->get_step($dao->db, { slug => 'pricing' });

    is $pricing_step->template, 'tenant-signup/pricing', 'Correct template path';
};

done_testing;