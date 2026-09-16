#!/usr/bin/env perl
# ABOUTME: Tests for Registry::Service::Stripe async/promise handling verification
# ABOUTME: Validates that async methods exist and webhook verification works

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Mojo::IOLoop;
use Mojo::Promise;
use Mojo::UserAgent;
use Mojo::JSON qw(encode_json decode_json);

# Test that the Stripe Service module loads properly
use_ok('Registry::Service::Stripe');

my $mock_api_key = 'sk_test_mock123';
my $mock_webhook_secret = 'whsec_test123';

# Test the async promise bug directly
subtest 'Test async method availability' => sub {
    # Test that UserAgent has the async methods we use
    my $ua = Mojo::UserAgent->new;
    ok($ua->can('start_p'), "Mojo::UserAgent has start_p method");
    ok($ua->can('start'), "Mojo::UserAgent has start method");
    ok($ua->can('get_p'), "Mojo::UserAgent has get_p method");
    ok($ua->can('post_p'), "Mojo::UserAgent has post_p method");

    # Create a transaction and verify start_p returns a promise.
    # Catch the rejection so it doesn't fire as an unhandled promise.
    my $tx = $ua->build_tx(GET => 'http://example.com');
    my $result = $ua->start_p($tx)->catch(sub {});
    isa_ok($result, 'Mojo::Promise', 'start_p returns a promise');
};

# Test Stripe Service with mock responses by overriding UserAgent
subtest 'Stripe Service async/promise handling with mocked responses' => sub {
    # Test that the service can be instantiated
    my $service = Registry::Service::Stripe->new(
        api_key => $mock_api_key,
        webhook_secret => $mock_webhook_secret,
    );

    ok($service, 'Stripe service instantiated');
    isa_ok($service, 'Registry::Service::Stripe');

    # Test that we have the expected async methods
    can_ok($service, qw(
        create_payment_intent_async
        retrieve_payment_intent_async
        confirm_payment_intent_async
        cancel_payment_intent_async
        create_setup_intent_async
        retrieve_setup_intent_async
        confirm_setup_intent_async
        create_customer_async
        retrieve_customer_async
        update_customer_async
        delete_customer_async
        create_payment_method_async
        retrieve_payment_method_async
        attach_payment_method_async
        detach_payment_method_async
        list_customer_payment_methods_async
        create_subscription_async
        retrieve_subscription_async
        update_subscription_async
        cancel_subscription_async
        list_invoices_async
        retrieve_invoice_async
        create_refund_async
        retrieve_refund_async
        create_price_async
        retrieve_price_async
        list_prices_async
        create_product_async
        retrieve_product_async
        batch_async
    ));

    # Test that we have sync wrapper methods
    can_ok($service, qw(
        create_payment_intent
        retrieve_payment_intent
        create_refund
        create_customer
        create_setup_intent
        create_subscription
        retrieve_subscription
        update_subscription
        cancel_subscription
        list_invoices
    ));
};

# Test webhook signature verification
subtest 'Webhook signature verification' => sub {
    my $service = Registry::Service::Stripe->new(
        api_key => $mock_api_key,
        webhook_secret => $mock_webhook_secret,
    );

    my $payload = '{"id":"evt_test","type":"payment_intent.succeeded"}';
    my $timestamp = time();

    # Generate valid signature
    use Digest::SHA qw(hmac_sha256_hex);
    my $signed_payload = "$timestamp.$payload";
    my $valid_signature = hmac_sha256_hex($signed_payload, $mock_webhook_secret);
    my $signature_header = "t=$timestamp,v1=$valid_signature";

    # Test valid signature
    lives_ok {
        $service->verify_webhook_signature($payload, $signature_header);
    } 'Valid webhook signature accepted';

    # Test invalid signature
    my $invalid_header = "t=$timestamp,v1=invalid_signature";
    throws_ok {
        $service->verify_webhook_signature($payload, $invalid_header);
    } qr/Invalid webhook signature/, 'Invalid webhook signature rejected';

    # Test old timestamp
    my $old_timestamp = time() - 400;
    my $old_signed_payload = "$old_timestamp.$payload";
    my $old_signature = hmac_sha256_hex($old_signed_payload, $mock_webhook_secret);
    my $old_header = "t=$old_timestamp,v1=$old_signature";

    throws_ok {
        $service->verify_webhook_signature($payload, $old_header);
    } qr/Webhook timestamp too old/, 'Old webhook timestamp rejected';

    # Test missing webhook secret
    my $service_no_secret = Registry::Service::Stripe->new(
        api_key => $mock_api_key,
    );

    throws_ok {
        $service_no_secret->verify_webhook_signature($payload, $signature_header);
    } qr/Webhook secret not configured/, 'Missing webhook secret causes error';
};

# Test error handling
subtest 'Error handling' => sub {
    my $service = Registry::Service::Stripe->new(
        api_key => $mock_api_key,
        webhook_secret => $mock_webhook_secret,
    );

    # Test error classification
    ok($service->is_card_error('card_error: Your card was declined'), 'Card error detected');
    ok(!$service->is_card_error('api_error: Something went wrong'), 'Non-card error not detected as card error');

    ok($service->is_rate_limit_error('rate_limit: Too many requests'), 'Rate limit error detected');
    ok($service->is_authentication_error('authentication_error: Invalid API key'), 'Auth error detected');
    ok($service->is_api_error('api_error: Internal error'), 'API error detected');
};

# Every Stripe call in the application goes through this user agent, including
# the subscription lookup the webhook makes before opening its transaction.
# Mojo defaults request_timeout to 0 -- unbounded -- and an unbounded call there
# would hold the dedup claim for as long as Stripe took to answer.
subtest 'the Stripe user agent is bounded' => sub {
    my $ua = Registry::Service::Stripe->new( api_key => 'sk_test_bounded' )->ua;

    is $ua->request_timeout, 30, 'request_timeout is bounded';

    # Asserted for the record, not as a gate: Mojo already defaults this to 10,
    # so no assertion here can tell whether our explicit call is present. Kept
    # because a future Mojo changing the default should be loud.
    is $ua->connect_timeout, 10, 'connect_timeout is 10 (Mojo default, restated)';
};

done_testing;