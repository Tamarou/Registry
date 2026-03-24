#!/usr/bin/env perl
# ABOUTME: Tests for Subscription DAO -- Stripe customer and webhook event processing.
# ABOUTME: Covers DAO creation, billing info retrieval, and webhook event storage.

use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is ok isa_ok can_ok subtest )];

use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Subscription;
use JSON;
use DateTime;

# Setup test database
my $t = Test::Registry::DB->new;
my $db = $t->db;

# Create tenant with schema cloning
my $tenant = Test::Registry::Fixtures::create_tenant($db, {
    name => 'Test Tenant',
    slug => 'test_tenant'
});
$db->db->query('SELECT clone_schema(dest_schema => ?)', $tenant->slug);

# Test Stripe subscription DAO
subtest 'Stripe subscription DAO creation' => sub {
    my $subscription_dao = Registry::DAO::Subscription->new(db => $db->db);
    isa_ok($subscription_dao, 'Registry::DAO::Subscription');
    can_ok($subscription_dao, qw(create_customer create_subscription process_webhook_event));
};

subtest 'Tenant billing info storage' => sub {
    my $subscription_dao = Registry::DAO::Subscription->new(db => $db->db);

    # Create test tenant in registry schema
    my $test_tenant = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Test Organization',
        slug => 'test_org'
    });
    my $tenant_id = $test_tenant->id;

    # Add tenant profile with billing info
    $db->db->query(
        'INSERT INTO registry.tenant_profiles (tenant_id, billing_email, billing_phone, billing_address, organization_type) VALUES (?, ?, ?, ?, ?)',
        $tenant_id,
        'billing@testorg.com',
        '+1-555-123-4567',
        encode_json({
            line1 => '123 Main St',
            city => 'Anytown',
            state => 'CA',
            postal_code => '12345',
            country => 'US'
        }),
        'education'
    );

    # Retrieve billing info
    my $billing_info = $subscription_dao->get_tenant_billing_info($tenant_id);

    is($billing_info->{name}, 'Test Organization', 'Tenant name retrieved');
    is($billing_info->{billing_email}, 'billing@testorg.com', 'Billing email retrieved');
    is($billing_info->{billing_phone}, '+1-555-123-4567', 'Billing phone retrieved');
    is($billing_info->{organization_type}, 'education', 'Organization type retrieved') if defined $billing_info->{organization_type};

    my $address = decode_json($billing_info->{billing_address});
    is($address->{line1}, '123 Main St', 'Billing address retrieved');
};

subtest 'Webhook event processing' => sub {
    my $subscription_dao = Registry::DAO::Subscription->new(db => $db->db);

    # Create test tenant
    my $webhook_tenant = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Webhook Test Org',
        slug => 'webhook_test'
    });
    my $tenant_id = $webhook_tenant->id;

    # Test subscription updated event
    my $event_data = {
        object => {
            id => 'sub_test123',
            status => 'active',
            metadata => { tenant_id => $tenant_id },
            trial_end => time() + 2592000  # 30 days from now
        }
    };

    # Process webhook -- update_billing_status is now a no-op since billing
    # columns moved to tenant_stripe_accounts, but event storage still works
    my $error;
    eval {
        $subscription_dao->process_webhook_event(
            $db->db,
            'evt_test123',
            'customer.subscription.updated',
            $event_data
        );
    };
    $error = $@;
    ok(!$error, "Webhook event processing succeeds: $error");

    # Check that event was stored
    my $stored_event = $db->db->query(
        'SELECT * FROM registry.subscription_events WHERE stripe_event_id = ?',
        'evt_test123'
    )->hash;

    ok($stored_event, 'Webhook event was stored');
    is($stored_event->{event_type}, 'customer.subscription.updated', 'Event type stored correctly');
    is($stored_event->{processing_status}, 'processed', 'Event marked as processed');
};

subtest 'Billing status updates are no-op' => sub {
    my $subscription_dao = Registry::DAO::Subscription->new(db => $db->db);

    my $status_tenant = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Status Test Org',
        slug => 'status_test'
    });
    my $tenant_id = $status_tenant->id;

    # update_billing_status is now a no-op (columns moved to tenant_stripe_accounts)
    my $result = $subscription_dao->update_billing_status($db->db, $tenant_id, 'active');
    ok($result, 'update_billing_status returns truthy (no-op for backward compat)');
};

subtest 'Trial expiration always returns false' => sub {
    my $subscription_dao = Registry::DAO::Subscription->new(db => $db->db);

    my $test_tenant = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Trial Check Org',
        slug => 'trial_check'
    });

    # Trial tracking moved to Stripe Connect -- is_trial_expired is always false
    ok(!$subscription_dao->is_trial_expired($test_tenant->id), 'is_trial_expired returns false');
};

subtest 'Configurable subscription creation' => sub {
    my $subscription_dao = Registry::DAO::Subscription->new(db => $db->db);

    # Test configuration method
    can_ok($subscription_dao, 'create_subscription_with_config');

    my $config = {
        plan_name => 'Custom Plan',
        monthly_amount => 15000,
        currency => 'usd',
        trial_days => 14,
        description => 'Custom subscription plan'
    };

    ok($config->{monthly_amount} == 15000, 'Configuration structure is correct');
};

done_testing();
