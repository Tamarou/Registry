#!/usr/bin/env perl
# ABOUTME: Tests for unified pricing engine supporting tenant-to-tenant relationships
# ABOUTME: Validates platform-as-tenant and cross-tenant pricing capabilities

use v5.34.0;
use warnings;
use utf8;
use experimental qw(signatures);

use Test::More;
use Test::Exception;
use Test::Deep;

use lib qw(lib t/lib);
use Test::Registry::DB;
use Test::Registry::Fixtures;

# These modules don't exist yet - they will fail until implemented
use Registry::PriceOps::UnifiedPricingEngine;
use Registry::PriceOps::TenantRelationships;
use Registry::DAO::TenantPricingRelationship;
use Registry::DAO::BillingPeriod;

# Setup test database
my $t  = Test::Registry::DB->new;
my $dao = $t->db;  # This returns Registry::DAO
my $db = $dao->db;  # Get the Mojo::Pg::Database object

# Platform tenant UUID
my $PLATFORM_ID = '00000000-0000-0000-0000-000000000000';

subtest 'Platform tenant exists' => sub {
    my $result = $db->query(
        'SELECT * FROM registry.tenants WHERE id = ?',
        $PLATFORM_ID
    );
    my $platform = $result->hash;

    ok($platform, 'Platform tenant exists');
    is($platform->{name}, 'Registry Platform', 'Platform name is correct');
    is($platform->{slug}, 'registry-platform', 'Platform slug is correct');
};

subtest 'Platform pricing plans exist' => sub {
    my $result = $db->query(
        'SELECT * FROM registry.pricing_plans WHERE offering_tenant_id = ? ORDER BY plan_name',
        $PLATFORM_ID
    );
    my $plans = $result->hashes;

    is(scalar @$plans, 3, 'Three platform pricing plans exist');

    # Verify revenue share plan
    my $revenue_share = $plans->[2];
    is($revenue_share->{plan_name}, 'Registry Revenue Share - 2%', 'Revenue share plan exists');
    is($revenue_share->{pricing_model_type}, 'percentage', 'Revenue share is percentage type');
    is($revenue_share->{plan_scope}, 'tenant', 'Revenue share is tenant scope');

    # Verify standard subscription plan
    my $standard = $plans->[1];
    is($standard->{plan_name}, 'Registry Standard - $200/month', 'Standard plan exists');
    is($standard->{pricing_model_type}, 'fixed', 'Standard is fixed type');
    is($standard->{amount}, '200.00', 'Standard plan amount is $200');

    # Verify hybrid plan
    my $hybrid = $plans->[0];
    is($hybrid->{plan_name}, 'Registry Plus - $100/month + 1%', 'Hybrid plan exists');
    is($hybrid->{pricing_model_type}, 'hybrid', 'Hybrid is hybrid type');
};

subtest 'Create tenant-to-tenant pricing relationship' => sub {
    # Create test tenants
    my $abc_org = Test::Registry::Fixtures::create_tenant($db, {
        name => 'ABC After School',
        slug => 'abc-afterschool',
    });

    my $payment_processor = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Payment Processor Inc',
        slug => 'payment-processor',
    });

    # Get standard platform plan
    my $standard_plan_result = $db->query(
        'SELECT * FROM registry.pricing_plans WHERE offering_tenant_id = ? AND metadata->>\'default\' = ?',
        $PLATFORM_ID, 'true'
    );
    my $standard_plan = $standard_plan_result->hash;

    # Create relationship using new unified engine
    my $engine = Registry::PriceOps::UnifiedPricingEngine->new(db => $db);

    my $relationship = $engine->subscribe_to_plan(
        payer_tenant => $abc_org->id,
        plan_id => $standard_plan->{id}
    );

    ok($relationship, 'Created tenant pricing relationship');
    is($relationship->payer_tenant_id, $abc_org->id, 'Payer tenant is correct');
    is($relationship->payee_tenant_id, $PLATFORM_ID, 'Payee is platform');
    is($relationship->relationship_type, 'platform_fee', 'Relationship type is platform_fee');
    ok($relationship->is_active, 'Relationship is active');
};

subtest 'Calculate billing for percentage-based pricing' => sub {
    # Create test tenant
    my $xyz_school = Test::Registry::Fixtures::create_tenant($db, {
        name => 'XYZ School Programs',
        slug => 'xyz-school',
    });

    # Get revenue share plan
    my $revenue_plan_result = $db->query(
        'SELECT * FROM registry.pricing_plans WHERE offering_tenant_id = ? AND pricing_model_type = ?',
        $PLATFORM_ID, 'percentage'
    );
    my $revenue_plan = $revenue_plan_result->hash;

    # Create relationship with revenue share
    my $engine = Registry::PriceOps::UnifiedPricingEngine->new(db => $db);
    my $relationship = $engine->subscribe_to_plan(
        payer_tenant => $xyz_school->id,
        plan_id => $revenue_plan->{id}
    );

    # Simulate customer payments for the month
    my $usage_data = {
        customer_payments => 10000.00,  # $10,000 in customer payments
        period_start => '2024-01-01',
        period_end => '2024-01-31',
    };

    my $billing = $engine->calculate_fees(
        relationship_id => $relationship->id,
        period => {
            start => $usage_data->{period_start},
            end => $usage_data->{period_end},
        },
        usage_data => $usage_data
    );

    ok($billing, 'Billing calculated');
    is($billing->{calculated_amount}, 200.00, '2% of $10,000 = $200');
    is($billing->{payment_status}, 'pending', 'Payment status is pending');
};

subtest 'Cross-tenant service relationships' => sub {
    # Create instructor as a tenant
    my $instructor = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Jane Smith - Instructor',
        slug => 'jane-smith',
    });

    my $org = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Community Center',
        slug => 'community-center',
    });

    # Organization creates revenue share plan for instructor
    my $engine = Registry::PriceOps::UnifiedPricingEngine->new(db => $db);
    my $instructor_plan = $engine->create_pricing_plan(
        offering_tenant => $org->id,
        configuration => {
            target_tenant_id => $instructor->id,
            plan_scope => 'tenant',
            plan_name => 'Instructor Revenue Share - 15%',
            pricing_model_type => 'percentage',
            pricing_configuration => {
                percentage => 0.15,
                applies_to => 'program_revenue',
            },
        }
    );

    ok($instructor_plan, 'Created instructor revenue share plan');
    is($instructor_plan->offering_tenant_id, $org->id, 'Offering tenant is organization');
    is($instructor_plan->target_tenant_id, $instructor->id, 'Target tenant is instructor');

    # Create relationship
    my $relationship = Registry::PriceOps::TenantRelationships->establish_relationship(
        $db,
        payer => $org->id,
        payee => $instructor->id,
        plan => $instructor_plan->id
    );

    ok($relationship, 'Established instructor revenue share relationship');
    is($relationship->relationship_type, 'revenue_share', 'Relationship type is revenue_share');
};

subtest 'Plan switching with relationship preservation' => sub {
    my $tenant = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Growing Organization',
        slug => 'growing-org',
    });

    # Start with standard plan
    my $standard_plan_result = $db->query(
        'SELECT * FROM registry.pricing_plans WHERE offering_tenant_id = ? AND plan_name LIKE ?',
        $PLATFORM_ID, '%Standard%'
    );
    my $standard_plan = $standard_plan_result->hash;

    my $engine = Registry::PriceOps::UnifiedPricingEngine->new(db => $db);
    my $relationship = $engine->subscribe_to_plan(
        payer_tenant => $tenant->id,
        plan_id => $standard_plan->{id}
    );

    my $original_relationship_id = $relationship->id;

    # Switch to revenue share plan
    my $revenue_plan_result = $db->query(
        'SELECT * FROM registry.pricing_plans WHERE offering_tenant_id = ? AND pricing_model_type = ?',
        $PLATFORM_ID, 'percentage'
    );
    my $revenue_plan = $revenue_plan_result->hash;

    my $updated_relationship = $engine->process_plan_switch(
        relationship_id => $relationship->id,
        new_plan_id => $revenue_plan->{id}
    );

    ok($updated_relationship, 'Plan switch successful');
    is($updated_relationship->id, $original_relationship_id, 'Relationship ID preserved');
    is($updated_relationship->pricing_plan_id, $revenue_plan->{id}, 'Plan updated to revenue share');
};

subtest 'Billing period constraints' => sub {
    my $tenant = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Test Billing Org',
        slug => 'test-billing',
    });

    # Create a relationship
    my $plan_result = $db->query(
        'SELECT * FROM registry.pricing_plans WHERE offering_tenant_id = ? LIMIT 1',
        $PLATFORM_ID
    );
    my $plan = $plan_result->hash;

    my $relationship = Registry::DAO::TenantPricingRelationship->create($db, {
        payer_tenant_id => $tenant->id,
        payee_tenant_id => $PLATFORM_ID,
        pricing_plan_id => $plan->{id},
        relationship_type => 'platform_fee',
    });

    # Create first billing period
    my $period1 = Registry::DAO::BillingPeriod->create($db, {
        pricing_relationship_id => $relationship->id,
        period_start => '2024-01-01',
        period_end => '2024-01-31',
        calculated_amount => 200.00,
    });

    ok($period1, 'First billing period created');

    # Try to create overlapping period - should fail
    throws_ok {
        Registry::DAO::BillingPeriod->create($db, {
            pricing_relationship_id => $relationship->id,
            period_start => '2024-01-15',
            period_end => '2024-02-15',
            calculated_amount => 200.00,
        });
    } qr/overlapping/, 'Cannot create overlapping billing periods';

    # Create non-overlapping period - should succeed
    my $period2 = Registry::DAO::BillingPeriod->create($db, {
        pricing_relationship_id => $relationship->id,
        period_start => '2024-02-01',
        period_end => '2024-02-29',
        calculated_amount => 200.00,
    });

    ok($period2, 'Non-overlapping billing period created');
};

subtest 'Multiple concurrent pricing relationships' => sub {
    my $tenant = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Multi-Service Org',
        slug => 'multi-service',
    });

    # Platform subscription
    my $platform_plan_result = $db->query(
        'SELECT * FROM registry.pricing_plans WHERE offering_tenant_id = ? LIMIT 1',
        $PLATFORM_ID
    );
    my $platform_plan = $platform_plan_result->hash;

    # Create payment processor tenant and plan
    my $processor = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Stripe Connect Partner',
        slug => 'stripe-partner',
    });

    my $engine = Registry::PriceOps::UnifiedPricingEngine->new(db => $db);
    my $processor_plan = $engine->create_pricing_plan(
        offering_tenant => $processor->id,
        configuration => {
            plan_scope => 'tenant',
            plan_name => 'Payment Processing Fees',
            pricing_model_type => 'transaction_fee',
            pricing_configuration => {
                per_transaction => 0.30,
                percentage => 0.029,
            },
        }
    );

    # Create multiple relationships
    my $platform_rel = $engine->subscribe_to_plan(
        payer_tenant => $tenant->id,
        plan_id => $platform_plan->{id}
    );

    my $processor_rel = $engine->subscribe_to_plan(
        payer_tenant => $tenant->id,
        plan_id => $processor_plan->id
    );

    # Verify both relationships exist and are active
    my $relationships_result = $db->query(
        'SELECT * FROM registry.tenant_pricing_relationships WHERE payer_tenant_id = ? AND is_active = true',
        $tenant->id
    );
    my $relationships = $relationships_result->hashes;

    is(scalar @$relationships, 2, 'Tenant has 2 active pricing relationships');

    my @relationship_types = sort map { $_->{relationship_type} } @$relationships;
    cmp_deeply(\@relationship_types, ['platform_fee', 'service_fee'], 'Correct relationship types');
};

subtest 'Unified pricing management interface' => sub {
    my $tenant = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Interface Test Org',
        slug => 'interface-test',
    });

    my $engine = Registry::PriceOps::UnifiedPricingEngine->new(db => $db);

    # Get all available plans for a tenant (marketplace view)
    my $available_plans = $engine->get_available_plans_for_tenant(
        tenant_id => $tenant->id,
        filters => {
            plan_scope => 'tenant',
        }
    );

    ok($available_plans, 'Retrieved available plans');
    ok(scalar @$available_plans >= 3, 'At least 3 platform plans available');

    # Get tenant's current relationships
    my $current_relationships = $engine->get_tenant_relationships(
        tenant_id => $tenant->id,
        include_inactive => 0
    );

    is(scalar @$current_relationships, 0, 'New tenant has no relationships');

    # Subscribe to a plan
    my $plan = $available_plans->[0];
    my $relationship = $engine->subscribe_to_plan(
        payer_tenant => $tenant->id,
        plan_id => $plan->{id}
    );

    # Verify relationship appears in list
    $current_relationships = $engine->get_tenant_relationships(
        tenant_id => $tenant->id,
        include_inactive => 0
    );

    is(scalar @$current_relationships, 1, 'Tenant now has 1 relationship');
};

done_testing;