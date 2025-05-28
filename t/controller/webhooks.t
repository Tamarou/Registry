#!/usr/bin/env perl

use 5.40.2;
use lib qw(lib t/lib);
use Test::More;
use Test::Mojo;

use Registry;
use Test::Registry::DB;
use JSON;

my $test_db_url = Test::Registry::DB->new_test_db();
local $ENV{DB_URL} = $test_db_url;

# Skip Minion for testing
my $app = Registry->new;
$app->plugin('Test::Minion');
my $t = Test::Mojo->new($app);

subtest 'Stripe webhook endpoint' => sub {
    plan tests => 5;
    
    # Test basic webhook endpoint exists
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
    
    # Test without signature (should still work for basic testing)
    $t->post_ok('/webhooks/stripe', {}, $payload)
      ->status_is(200)
      ->content_is('OK');
    
    # Test with invalid JSON
    $t->post_ok('/webhooks/stripe', {}, 'invalid json')
      ->status_is(400)
      ->content_like(qr/Invalid JSON/);
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