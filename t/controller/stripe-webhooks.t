#!/usr/bin/env perl

use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is ok isa_ok can_ok subtest )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;
use Registry::Controller::Webhooks;
use JSON;

my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );
my $db = $dao->db;

subtest 'Webhook controller creation' => sub {
    my $webhook_controller = Registry::Controller::Webhooks->new;
    isa_ok($webhook_controller, 'Registry::Controller::Webhooks');
    can_ok($webhook_controller, qw(stripe _verify_stripe_signature));
};

subtest 'Signature verification' => sub {
    my $webhook_controller = Registry::Controller::Webhooks->new;
    
    # Test with no secret (should pass)
    ok($webhook_controller->_verify_stripe_signature('payload', 'sig', ''), 
       'No secret verification passes');
    
    # Test with invalid signature format
    ok(!$webhook_controller->_verify_stripe_signature('payload', 'invalid', 'secret'),
       'Invalid signature format fails');
};

subtest 'Webhook processing logic' => sub {
    # Test the subscription DAO webhook processing directly
    use Registry::DAO::Subscription;
    my $subscription_dao = Registry::DAO::Subscription->new(db => $db);
    
    my $event_data = {
        object => {
            id => 'sub_test123',
            status => 'active',
            metadata => { tenant_id => 'test-tenant-id' }
        }
    };
    
    # Process webhook event
    my $result = $subscription_dao->process_webhook_event(
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
    
    ok($stored_event, 'Webhook event stored in database');
    is($stored_event->{event_type}, 'customer.subscription.updated', 'Event type stored correctly');
};