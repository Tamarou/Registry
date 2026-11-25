#!/usr/bin/env perl
# ABOUTME: Test that PricingPlan is relationship-agnostic and focuses on plan definition
# ABOUTME: Verifies clean separation between pricing plans and pricing relationships

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Registry::DAO;
use Registry::DAO::PricingPlan;
use Registry::DAO::Tenant;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::WorkflowSteps::PricingPlanBasics;
use Test::Registry::DB;

# Test that PricingPlan doesn't have obsolete relationship fields
subtest 'PricingPlan should not have relationship fields' => sub {
    # Create a plan instance for testing
    my $plan = eval {
        Registry::DAO::PricingPlan->new(
            id => '123e4567-e89b-12d3-a456-426614174000',
            session_id => '223e4567-e89b-12d3-a456-426614174000',
            plan_name => 'Test Plan',
            amount_cents => 10000,
            created_at => '2024-01-01T00:00:00Z',
            updated_at => '2024-01-01T00:00:00Z',
        );
    };

    ok($plan, 'Created plan instance') or diag("Error: $@");

    # These fields should NOT exist
    ok(!$plan->can('target_tenant_id'), 'PricingPlan should not have target_tenant_id field');
    ok(!$plan->can('offering_tenant_id'), 'PricingPlan should not have offering_tenant_id field');

    # These fields SHOULD exist (core plan definition)
    ok($plan->can('plan_name'), 'PricingPlan should have plan_name field');
    ok($plan->can('amount_cents'), 'PricingPlan should have amount_cents field');
    ok($plan->can('requirements'), 'PricingPlan should have requirements field');
};

subtest 'get_tenant_id resolves registry and a provisioned tenant by lookup' => sub {
    my $test_db = Test::Registry::DB->new;
    my $dao     = $test_db->db;
    my $db      = $dao->db;

    my $workflow = Registry::DAO::Workflow->create($db, {
        name        => 'Pricing Plan Tenant Lookup',
        slug        => 'pricing-plan-tenant-lookup',
        description => 'Resolves the tenant a pricing plan is created for',
    });
    Registry::DAO::WorkflowStep->create($db, {
        workflow_id => $workflow->id,
        slug        => 'basics',
        class       => 'Registry::DAO::WorkflowSteps::PricingPlanBasics',
        description => 'Pricing plan basics',
    });
    $workflow->update($db, { first_step => 'basics' }, { id => $workflow->id });
    my $step = $workflow->get_step($db, { slug => 'basics' });

    my $platform = Registry::DAO::Tenant->platform($db);
    is $platform->id,
        $db->query(q{SELECT id FROM registry.tenants WHERE slug = 'registry'})->hash->{id},
        'platform() is the registry row';

    my $platform_run = $workflow->new_run($db);
    $platform_run->update_data($db, { __tenant_slug => 'registry' });
    is $step->get_tenant_id($db, $platform_run), $platform->id,
        'registry resolves to the registry row id';

    my $admin = $dao->create(User => {
        username => 'pricing_lookup_admin', user_type => 'admin',
        email => 'pricing-lookup@example.com', name => 'Lookup Admin',
    });
    my $tenant = Registry::DAO::Tenant->provision($db, {
        name => 'Lookup Studio', slug => 'lookup_studio', users => [$admin],
    });

    my $tenant_run = $workflow->new_run($db);
    $tenant_run->update_data($db, { __tenant_slug => 'lookup_studio' });
    is $step->get_tenant_id($db, $tenant_run), $tenant->id,
        "a provisioned tenant's slug resolves to its id";
};

done_testing();
