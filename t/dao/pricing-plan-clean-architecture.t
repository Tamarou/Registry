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

done_testing();
