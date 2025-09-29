#!/usr/bin/env perl
# ABOUTME: Test suite for unified PricingRelationship DAO
# ABOUTME: Validates all pricing relationship types (platform, B2C, B2B)

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
use Registry::DAO::PricingRelationship;
use Registry::DAO::PricingPlan;
use Registry::DAO::User;
use Registry::DAO::Tenant;

# Initialize test database
my $test_db = Test::Registry::DB->new;
my $dao = $test_db->db;
my $db = $dao->db;

# Test basic creation
subtest 'Create pricing relationship' => sub {
    my $tenant = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Test Provider',
        slug => 'test_provider',
    });

    my $user = Registry::DAO::User->create($db, {
        username => 'test_consumer',
        passhash => '$2b$12$DummyHashForTesting',
    });

    # Create a pricing plan
    my $plan = Registry::DAO::PricingPlan->create($db, {
        plan_name => 'Test Plan',
        plan_type => 'standard',
        pricing_model_type => 'fixed',
        amount => 100.00,
        offering_tenant_id => $tenant->id,
        plan_scope => 'customer',
    });

    # Create relationship
    my $relationship = Registry::DAO::PricingRelationship->create($db, {
        provider_id => $tenant->id,
        consumer_id => $user->id,
        pricing_plan_id => $plan->id,
        status => 'active',
    });

    ok($relationship, 'Created pricing relationship');
    is($relationship->provider_id, $tenant->id, 'Provider ID set correctly');
    is($relationship->consumer_id, $user->id, 'Consumer ID set correctly');
    is($relationship->status, 'active', 'Status set correctly');
};

# Test platform relationships
subtest 'Platform billing relationships' => sub {
    my $platform_id = '00000000-0000-0000-0000-000000000000';

    my $tenant = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Customer Tenant',
        slug => 'customer_tenant',
    });

    my $admin_user = Registry::DAO::User->create($db, {
        username => 'tenant_admin',
        passhash => '$2b$12$DummyHashForTesting',
    });

    # Associate user with tenant
    $db->insert('tenant_users', {
        tenant_id => $tenant->id,
        user_id => $admin_user->id,
        is_primary => 1,
    });

    # Create platform pricing plan
    my $plan = Registry::DAO::PricingPlan->create($db, {
        plan_name => 'Platform Standard',
        plan_type => 'subscription',
        pricing_model_type => 'fixed',
        amount => 200.00,
        offering_tenant_id => $platform_id,
        plan_scope => 'tenant',
    });

    # Create platform -> tenant relationship
    my $relationship = Registry::DAO::PricingRelationship->create($db, {
        provider_id => $platform_id,
        consumer_id => $admin_user->id,
        pricing_plan_id => $plan->id,
        status => 'active',
    });

    ok($relationship, 'Created platform relationship');
    is($relationship->provider_id, $platform_id, 'Platform is provider');

    # Verify relationship type detection
    my $type = $relationship->get_relationship_type($db);
    is($type, 'platform_billing', 'Correctly identified as platform billing');
};

# Test B2C enrollments
subtest 'B2C enrollment relationships' => sub {
    my $program_tenant = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Program Provider',
        slug => 'program_provider',
    });

    my $parent_user = Registry::DAO::User->create($db, {
        username => 'parent_user',
        passhash => '$2b$12$DummyHashForTesting',
    });

    # Create enrollment pricing plan
    my $plan = Registry::DAO::PricingPlan->create($db, {
        plan_name => 'Summer Camp Fee',
        plan_type => 'enrollment',
        pricing_model_type => 'fixed',
        amount => 500.00,
        offering_tenant_id => $program_tenant->id,
        plan_scope => 'customer',
        # session_id => '123e4567-e89b-12d3-a456-426614174000', # Would be from a real session
    });

    # Create program -> parent relationship
    my $relationship = Registry::DAO::PricingRelationship->create($db, {
        provider_id => $program_tenant->id,
        consumer_id => $parent_user->id,
        pricing_plan_id => $plan->id,
        status => 'active',
        metadata => {
            enrollment_id => '123e4567-e89b-12d3-a456-426614174000',
            child_name => 'Test Child',
        },
    });

    ok($relationship, 'Created B2C enrollment relationship');
    is($relationship->metadata->{child_name}, 'Test Child', 'Metadata preserved');

    # Verify relationship type
    my $type = $relationship->get_relationship_type($db);
    is($type, 'b2c_enrollment', 'Correctly identified as B2C enrollment');
};

# Test B2B relationships
subtest 'B2B corporate relationships' => sub {
    my $service_tenant = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Service Provider',
        slug => 'service_provider',
    });

    my $corporate_tenant = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Corporate Client',
        slug => 'corporate_client',
    });

    my $corporate_admin = Registry::DAO::User->create($db, {
        username => 'corporate_admin',
        passhash => '$2b$12$DummyHashForTesting',
    });

    # Associate user with corporate tenant
    $db->insert('tenant_users', {
        tenant_id => $corporate_tenant->id,
        user_id => $corporate_admin->id,
        is_primary => 1,
    });

    # Create B2B service plan
    my $plan = Registry::DAO::PricingPlan->create($db, {
        plan_name => 'Corporate Discount Plan',
        plan_type => 'partnership',
        pricing_model_type => 'percentage',
        amount => 0.15,  # 15% discount
        offering_tenant_id => $service_tenant->id,
        plan_scope => 'tenant',
    });

    # Create service -> corporate relationship
    my $relationship = Registry::DAO::PricingRelationship->create($db, {
        provider_id => $service_tenant->id,
        consumer_id => $corporate_admin->id,
        pricing_plan_id => $plan->id,
        status => 'active',
    });

    ok($relationship, 'Created B2B relationship');

    # Verify relationship type
    my $type = $relationship->get_relationship_type($db);
    is($type, 'b2b_partnership', 'Correctly identified as B2B partnership');
};

# Test finding relationships
subtest 'Find relationships' => sub {
    my $tenant = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Find Test Provider',
        slug => 'find_test_provider',
    });

    my $user1 = Registry::DAO::User->create($db, {
        username => 'user_one',
        passhash => '$2b$12$DummyHashForTesting',
    });

    my $user2 = Registry::DAO::User->create($db, {
        username => 'user_two',
        passhash => '$2b$12$DummyHashForTesting',
    });

    my $plan = Registry::DAO::PricingPlan->create($db, {
        plan_name => 'Test Plan',
        plan_type => 'standard',
        pricing_model_type => 'fixed',
        amount => 50.00,
        offering_tenant_id => $tenant->id,
    });

    # Create multiple relationships
    my $rel1 = Registry::DAO::PricingRelationship->create($db, {
        provider_id => $tenant->id,
        consumer_id => $user1->id,
        pricing_plan_id => $plan->id,
    });

    my $rel2 = Registry::DAO::PricingRelationship->create($db, {
        provider_id => $tenant->id,
        consumer_id => $user2->id,
        pricing_plan_id => $plan->id,
    });

    # Find by provider
    my @provider_rels = Registry::DAO::PricingRelationship->find($db, {
        provider_id => $tenant->id,
    });
    is(@provider_rels, 2, 'Found relationships by provider');

    # Find by consumer
    my @consumer_rels = Registry::DAO::PricingRelationship->find($db, {
        consumer_id => $user1->id,
    });
    is(@consumer_rels, 1, 'Found relationship by consumer');

    # Find by ID
    my $found = Registry::DAO::PricingRelationship->find_by_id($db, $rel1->id);
    ok($found, 'Found relationship by ID');
    is($found->id, $rel1->id, 'Correct relationship found');
};

# Test status transitions
subtest 'Status transitions' => sub {
    my $tenant = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Status Test Provider',
        slug => 'status_test_provider',
    });

    my $user = Registry::DAO::User->create($db, {
        username => 'status_test_user',
        passhash => '$2b$12$DummyHashForTesting',
    });

    my $plan = Registry::DAO::PricingPlan->create($db, {
        plan_name => 'Test Plan',
        plan_type => 'standard',
        pricing_model_type => 'fixed',
        amount => 100.00,
        offering_tenant_id => $tenant->id,
    });

    my $relationship = Registry::DAO::PricingRelationship->create($db, {
        provider_id => $tenant->id,
        consumer_id => $user->id,
        pricing_plan_id => $plan->id,
        status => 'pending',
    });

    # Activate
    $relationship->activate($db);
    is($relationship->status, 'active', 'Activated relationship');

    # Suspend
    $relationship->suspend($db);
    is($relationship->status, 'suspended', 'Suspended relationship');

    # Cancel
    $relationship->cancel($db);
    is($relationship->status, 'cancelled', 'Cancelled relationship');
    ok($relationship->metadata->{cancelled_at}, 'Cancellation timestamp recorded');
};

# Test relationship helpers
subtest 'Relationship helpers' => sub {
    my $tenant = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Helper Test Provider',
        slug => 'helper_test_provider',
    });

    my $user = Registry::DAO::User->create($db, {
        username => 'helper_test_user',
        passhash => '$2b$12$DummyHashForTesting',
    });

    my $plan = Registry::DAO::PricingPlan->create($db, {
        plan_name => 'Test Plan',
        plan_type => 'standard',
        pricing_model_type => 'fixed',
        amount => 100.00,
        offering_tenant_id => $tenant->id,
    });

    my $relationship = Registry::DAO::PricingRelationship->create($db, {
        provider_id => $tenant->id,
        consumer_id => $user->id,
        pricing_plan_id => $plan->id,
    });

    # Get pricing plan
    my $fetched_plan = $relationship->get_pricing_plan($db);
    ok($fetched_plan, 'Got pricing plan');
    is($fetched_plan->id, $plan->id, 'Correct plan retrieved');

    # Get provider tenant
    my $provider = $relationship->get_provider_tenant($db);
    ok($provider, 'Got provider tenant');
    is($provider->id, $tenant->id, 'Correct provider retrieved');

    # Get consumer user
    my $consumer = $relationship->get_consumer_user($db);
    ok($consumer, 'Got consumer user');
    is($consumer->id, $user->id, 'Correct consumer retrieved');

    # Get consumer's tenant (if applicable)
    my $consumer_tenant = $relationship->get_consumer_tenant($db);
    ok(defined $consumer_tenant, 'Consumer tenant check works');
};

done_testing();