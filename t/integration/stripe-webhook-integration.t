#!/usr/bin/env perl

use 5.40.2;
use lib qw(lib t/lib);
use Test::More;

use Registry::DAO;
use Registry::Controller::Webhooks;
use Test::Registry::DB;
use JSON;

my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;
my $db = $dao->db;

subtest 'Webhook controller basic functionality' => sub {
    plan tests => 2;
    
    my $webhook_controller = Registry::Controller::Webhooks->new();
    isa_ok($webhook_controller, 'Registry::Controller::Webhooks');
    can_ok($webhook_controller, 'stripe');
};

subtest 'Webhook signature verification' => sub {
    plan tests => 4;
    
    my $webhook_controller = Registry::Controller::Webhooks->new();
    
    # Test without endpoint secret (should pass)
    my $result1 = $webhook_controller->_verify_stripe_signature('payload', 'signature', undef);
    is($result1, 1, 'Verification passes when no secret configured');
    
    # Test with missing signature components
    my $result2 = $webhook_controller->_verify_stripe_signature('payload', 'invalid', 'secret');
    is($result2, 0, 'Verification fails with invalid signature format');
    
    # Test with old timestamp
    my $old_time = time() - 400; # 6+ minutes old
    my $old_sig = "t=$old_time,v1=signature";
    my $result3 = $webhook_controller->_verify_stripe_signature('payload', $old_sig, 'secret');
    is($result3, 0, 'Verification fails with old timestamp');
    
    # Test with recent timestamp but wrong signature
    my $recent_time = time() - 60; # 1 minute old
    my $recent_sig = "t=$recent_time,v1=wrongsignature";
    my $result4 = $webhook_controller->_verify_stripe_signature('payload', $recent_sig, 'secret');
    ok(!$result4, 'Verification fails with wrong signature');
};

subtest 'Integration with subscription DAO' => sub {
    plan tests => 3;
    
    use Registry::DAO::Subscription;
    
    my $subscription_dao = Registry::DAO::Subscription->new(db => $db);
    
    # Create test tenant
    my $tenant_result = $db->query(
        'INSERT INTO registry.tenants (name, slug, stripe_customer_id, stripe_subscription_id) VALUES (?, ?, ?, ?) RETURNING id',
        'Integration Test Org', 'integration-test', 'cus_integration123', 'sub_integration456'
    );
    my $tenant_id = $tenant_result->hash->{id};
    
    # Test full webhook event processing flow
    my $event_data = {
        object => {
            id => 'sub_integration456',
            status => 'active',
            metadata => { tenant_id => $tenant_id },
            trial_end => time() + 86400  # 1 day from now
        }
    };
    
    # Process the webhook event
    my $result = $subscription_dao->process_webhook_event(
        $db,
        'evt_integration789',
        'customer.subscription.updated',
        $event_data
    );
    
    ok($result, 'Webhook event processed successfully');
    
    # Verify tenant status was updated
    my $updated_tenant = $db->query(
        'SELECT billing_status FROM registry.tenants WHERE id = ?',
        $tenant_id
    )->hash;
    
    is($updated_tenant->{billing_status}, 'active', 'Tenant billing status updated correctly');
    
    # Verify event was logged
    my $logged_event = $db->query(
        'SELECT processing_status FROM registry.subscription_events WHERE stripe_event_id = ?',
        'evt_integration789'
    )->hash;
    
    is($logged_event->{processing_status}, 'processed', 'Event logged with correct status');
};

done_testing();