#!/usr/bin/env perl

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Mojo;

use Registry;
use Test::Registry::DB;
use JSON;

my $test_db = Test::Registry::DB->new();
local $ENV{DB_URL} = $test_db->uri;

# Skip Minion for testing
my $app = Registry->new;
# Mock Minion functionality for testing - Test::Minion doesn't exist
# $app->plugin('Test::Minion');
my $t = Test::Mojo->new($app);

subtest 'Stripe webhook rejects requests without STRIPE_WEBHOOK_SECRET' => sub {
    plan tests => 3;

    # Without STRIPE_WEBHOOK_SECRET set, the endpoint must reject all requests.
    # This prevents forged payment confirmations when the secret is misconfigured.
    local $ENV{STRIPE_WEBHOOK_SECRET};
    delete $ENV{STRIPE_WEBHOOK_SECRET};

    my $payload = encode_json({
        id => 'evt_test123',
        type => 'customer.subscription.updated',
        data => {
            object => {
                id => 'sub_test123',
                status => 'active',
                metadata => { tenant_id => 'test-tenant-id' }
            }
        }
    });

    $t->post_ok('/webhooks/stripe', {}, $payload)
      ->status_is(500)
      ->content_like(qr/not configured/);
};

subtest 'Webhook signature verification' => sub {
    plan tests => 3;
    
    # Test with invalid signature when STRIPE_WEBHOOK_SECRET is set
    local $ENV{STRIPE_WEBHOOK_SECRET} = 'whsec_test123';
    
    my $payload = encode_json({
        id => 'evt_test456',
        type => 'customer.subscription.updated',
        data => { object => {} }
    });
    
    # Test with no signature header
    $t->post_ok('/webhooks/stripe', {}, $payload)
      ->status_is(400)
      ->content_like(qr/Invalid signature/);
};

done_testing();