#!/usr/bin/env perl

use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is ok isa_ok can_ok subtest )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;
use Registry::DAO::Subscription;
use JSON;
use DateTime;

my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );
my $db = $dao->db;

# Test Stripe subscription DAO
subtest 'Stripe subscription DAO creation' => sub {
    my $subscription_dao = Registry::DAO::Subscription->new(db => $db);
    isa_ok($subscription_dao, 'Registry::DAO::Subscription');
    can_ok($subscription_dao, qw(create_customer create_subscription process_webhook_event));
};

subtest 'Tenant billing info storage' => sub {
    my $subscription_dao = Registry::DAO::Subscription->new(db => $db);
    
    # Create test tenant
    my $tenant_result = $db->query(
        'INSERT INTO registry.tenants (name, slug) VALUES (?, ?) RETURNING id',
        'Test Organization', 'test-org'
    );
    my $tenant_id = $tenant_result->hash->{id};
    
    # Add tenant profile with billing info
    $db->query(
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
    my $subscription_dao = Registry::DAO::Subscription->new(db => $db);
    
    # Create test tenant with subscription info
    my $tenant_result = $db->query(
        'INSERT INTO registry.tenants (name, slug, stripe_customer_id, stripe_subscription_id, billing_status) VALUES (?, ?, ?, ?, ?) RETURNING id',
        'Webhook Test Org', 'webhook-test', 'cus_test123', 'sub_test123', 'trial'
    );
    my $tenant_id = $tenant_result->hash->{id};
    
    # Test subscription updated event
    my $event_data = {
        object => {
            id => 'sub_test123',
            status => 'active',
            metadata => { tenant_id => $tenant_id },
            trial_end => time() + 2592000  # 30 days from now
        }
    };
    
    # Process webhook (this should work even without actual Stripe API calls)
    my $error;
    eval {
        $subscription_dao->process_webhook_event(
            'evt_test123',
            'customer.subscription.updated',
            $event_data
        );
    };
    $error = $@;
    ok(!$error, "Webhook event processing succeeds: $error");
    
    # Check that event was stored
    my $stored_event = $db->query(
        'SELECT * FROM registry.subscription_events WHERE stripe_event_id = ?',
        'evt_test123'
    )->hash;
    
    ok($stored_event, 'Webhook event was stored');
    is($stored_event->{event_type}, 'customer.subscription.updated', 'Event type stored correctly');
    is($stored_event->{processing_status}, 'processed', 'Event marked as processed');
    
    # Verify tenant status was updated
    my $updated_tenant = $db->query(
        'SELECT billing_status FROM registry.tenants WHERE id = ?',
        $tenant_id
    )->hash;
    
    is($updated_tenant->{billing_status}, 'active', 'Tenant billing status updated');
};

subtest 'Billing status updates' => sub {
    my $subscription_dao = Registry::DAO::Subscription->new(db => $db);
    
    # Create test tenant
    my $tenant_result = $db->query(
        'INSERT INTO registry.tenants (name, slug, billing_status) VALUES (?, ?, ?) RETURNING id',
        'Status Test Org', 'status-test', 'trial'
    );
    my $tenant_id = $tenant_result->hash->{id};
    
    # Update billing status
    $subscription_dao->update_billing_status($tenant_id, 'active');
    
    my $tenant = $db->query(
        'SELECT billing_status FROM registry.tenants WHERE id = ?',
        $tenant_id
    )->hash;
    
    is($tenant->{billing_status}, 'active', 'Billing status updated to active');
    
    # Test status update with subscription data
    my $subscription_data = { trial_end => time() + 1296000 }; # 15 days from now
    $subscription_dao->update_billing_status($tenant_id, 'trial', $subscription_data);
    
    my $updated_tenant = $db->query(
        'SELECT billing_status, trial_ends_at FROM registry.tenants WHERE id = ?',
        $tenant_id
    )->hash;
    
    is($updated_tenant->{billing_status}, 'trial', 'Billing status updated to trial');
    ok($updated_tenant->{trial_ends_at}, 'Trial end date was set');
};

subtest 'Trial expiration check' => sub {
    my $subscription_dao = Registry::DAO::Subscription->new(db => $db);
    
    # Create tenant with expired trial
    my $expired_tenant = $db->query(
        'INSERT INTO registry.tenants (name, slug, trial_ends_at) VALUES (?, ?, ?) RETURNING id',
        'Expired Trial Org', 'expired-trial', '2024-01-01T00:00:00Z'
    )->hash;
    
    # Create tenant with active trial
    my $active_trial_end = DateTime->now->add(days => 15)->iso8601();
    my $active_tenant = $db->query(
        'INSERT INTO registry.tenants (name, slug, trial_ends_at) VALUES (?, ?, ?) RETURNING id',
        'Active Trial Org', 'active-trial', $active_trial_end
    )->hash;
    
    ok($subscription_dao->is_trial_expired($expired_tenant->{id}), 'Expired trial detected');
    ok(!$subscription_dao->is_trial_expired($active_tenant->{id}), 'Active trial not expired');
};

done_testing;