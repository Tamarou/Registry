#!/usr/bin/env perl
# ABOUTME: Tests for Stripe webhook controller signature verification and processing.
# ABOUTME: Validates that webhooks require STRIPE_WEBHOOK_SECRET and proper signatures.

use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is ok isa_ok can_ok subtest like )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;
use Registry::Controller::Webhooks;
use JSON;

my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;
my $db = $dao->db;

subtest 'Webhook controller creation' => sub {
    my $webhook_controller = Registry::Controller::Webhooks->new;
    isa_ok($webhook_controller, 'Registry::Controller::Webhooks');
    can_ok($webhook_controller, qw(stripe _verify_stripe_signature));
};

subtest 'Signature verification' => sub {
    my $webhook_controller = Registry::Controller::Webhooks->new;

    # Empty secret should fail (no bypass)
    ok(!$webhook_controller->_verify_stripe_signature('payload', 'sig', ''),
       'Empty secret fails verification');

    # Missing signature header should fail
    ok(!$webhook_controller->_verify_stripe_signature('payload', '', 'secret'),
       'Missing signature fails');

    # Invalid signature format should fail
    ok(!$webhook_controller->_verify_stripe_signature('payload', 'invalid', 'secret'),
       'Invalid signature format fails');
};

subtest 'Webhook processing logic' => sub {
    # Subscription DAO requires STRIPE_SECRET_KEY
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_fake_for_testing';

    require Registry::DAO::Subscription;
    my $subscription_dao = Registry::DAO::Subscription->new(db => $db);

    # Create a test tenant to get a valid UUID
    my $tenant_id = $db->query(
        'INSERT INTO registry.tenants (name, slug) VALUES (?, ?) RETURNING id',
        'Test Tenant Webhook', 'test-tenant-webhook'
    )->hash->{id};

    my $event_data = {
        object => {
            id => 'sub_test123',
            status => 'active',
            metadata => { tenant_id => $tenant_id }
        }
    };

    # Process webhook event
    my $result = $subscription_dao->process_webhook_event(
        $dao->db,
        'evt_webhook_controller_test',
        'customer.subscription.updated',
        $event_data
    );

    ok($result, 'Webhook processing returns success');

    # Verify event was stored
    my $stored_event = $db->query(
        'SELECT * FROM registry.subscription_events WHERE stripe_event_id = ?',
        'evt_webhook_controller_test'
    )->hash;

    ok($stored_event, 'Event was stored in database');
    is($stored_event->{event_type}, 'customer.subscription.updated', 'Event type stored correctly');
};
