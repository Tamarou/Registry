#!/usr/bin/env perl
# ABOUTME: Test that PricingPlan is relationship-agnostic and focuses on plan definition
# ABOUTME: Verifies clean separation between pricing plans and pricing relationships

use 5.40.2;
use warnings;
use utf8;
use experimental 'signatures';

use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO;
use Registry::DAO::PricingPlan;
use Registry::DAO::PricingRelationship;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Mojo::JSON qw(true false);

my $db = Test::Registry::DB->new->db;

# Test that PricingPlan doesn't have obsolete relationship fields
subtest 'PricingPlan should not have relationship fields' => sub {
    # Create a plan instance for testing
    my $plan = eval {
        Registry::DAO::PricingPlan->new(
            id => '123e4567-e89b-12d3-a456-426614174000',
            session_id => '223e4567-e89b-12d3-a456-426614174000',
            plan_name => 'Test Plan',
            amount => 100.00,
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
    ok($plan->can('amount'), 'PricingPlan should have amount field');
    ok($plan->can('plan_scope'), 'PricingPlan should have plan_scope field');
    ok($plan->can('requirements'), 'PricingPlan should have requirements field');
};

subtest 'Create PricingPlan without relationship fields' => sub {
    # Create a plan with absolute minimal data to isolate the issue
    my $plan = Registry::DAO::PricingPlan->create($db, {
        plan_name => 'Minimal Plan',
        amount => 100.00,
    });

    ok($plan, 'Created plan without relationship fields');
    is($plan->plan_name, 'Minimal Plan', 'Plan name is correct');
    is($plan->amount, 100.00, 'Amount is correct');
    is($plan->plan_scope, 'customer', 'Plan scope is correct (default)');

    # Verify in database that relationship columns don't exist
    my $result = $db->query(q{
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = 'registry'
        AND table_name = 'pricing_plans'
        AND column_name IN ('target_tenant_id', 'offering_tenant_id')
    });

    is($result->rows, 0, 'Database should not have target_tenant_id or offering_tenant_id columns');
};

subtest 'Relationships handled by PricingRelationship' => sub {
    # Create a tenant (provider)
    my $tenant = Registry::DAO::Tenant->create($db, {
        name => 'Provider Tenant',
        slug => 'provider-' . time(),
    });

    # Create a user (consumer)
    my $user = Test::Registry::Fixtures->create_user($db, {
        username => 'consumer_' . time(),
        email => 'consumer@example.com',
    });

    # Create a pricing plan (no relationships embedded)
    my $plan = Registry::DAO::PricingPlan->create($db, {
        plan_name => 'Service Plan',
        plan_type => 'standard',
        amount => 200.00,
        plan_scope => 'tenant',  # Indicates this is for tenant-to-tenant
    });

    # Relationships are created separately in PricingRelationship
    my $relationship = Registry::DAO::PricingRelationship->create($db, {
        provider_id => $tenant->id,
        consumer_id => $user->id,
        pricing_plan_id => $plan->id,
        status => 'active',
    });

    ok($relationship, 'Created pricing relationship');
    is($relationship->provider_id, $tenant->id, 'Provider is correct');
    is($relationship->consumer_id, $user->id, 'Consumer is correct');
    is($relationship->pricing_plan_id, $plan->id, 'Plan is linked correctly');

    # Verify plan has no knowledge of specific relationships
    my $fetched_plan = Registry::DAO::PricingPlan->find_by_id($db, $plan->id);
    ok($fetched_plan, 'Retrieved plan');

    # Plan should only define what's offered, not to whom
    is($fetched_plan->plan_scope, 'tenant', 'Plan scope indicates tenant-level pricing');
    is($fetched_plan->amount, 200.00, 'Plan amount is defined');
};

subtest 'Platform plans without embedded relationships' => sub {
    # Platform plans should also not have embedded relationships

    # Create a platform-scope plan
    my $platform_plan = Registry::DAO::PricingPlan->create($db, {
        plan_name => 'Registry Standard - $200/month',
        plan_type => 'subscription',
        pricing_model_type => 'fixed',
        amount => 200.00,
        currency => 'USD',
        plan_scope => 'platform',  # Platform-level plan
        pricing_configuration => {
            monthly_amount => 200.00,
            includes => ['unlimited_programs', 'unlimited_enrollments', 'email_support']
        },
        metadata => {
            description => 'Standard monthly subscription',
            default => true,
        }
    });

    ok($platform_plan, 'Created platform plan');
    is($platform_plan->plan_scope, 'platform', 'Plan scope is platform');

    # Platform tenant ID should be in relationships, not in the plan
    my $platform_id = '00000000-0000-0000-0000-000000000000';

    # When a tenant subscribes, create a relationship
    my $tenant = Registry::DAO::Tenant->create($db, {
        name => 'Subscriber Tenant',
        slug => 'subscriber-' . time(),
    });

    my $admin_user = Test::Registry::Fixtures->create_user($db, {
        username => 'admin_' . time(),
        email => 'admin@subscriber.com',
    });

    my $subscription = Registry::DAO::PricingRelationship->create($db, {
        provider_id => $platform_id,  # Platform is provider
        consumer_id => $admin_user->id,  # Tenant admin is consumer
        pricing_plan_id => $platform_plan->id,
        status => 'active',
        metadata => {
            relationship_type => 'platform_billing',
            tenant_id => $tenant->id,  # Track which tenant this is for
        }
    });

    ok($subscription, 'Created platform subscription relationship');
    is($subscription->provider_id, $platform_id, 'Platform is the provider');
    is($subscription->pricing_plan_id, $platform_plan->id, 'Correct plan linked');
};

done_testing();