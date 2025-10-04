#!/usr/bin/env perl
# ABOUTME: Test to demonstrate the async/promise bug in Stripe Service
# ABOUTME: Shows the actual error when using the service

use 5.40.2;
use warnings;
use experimental 'signatures', 'try';
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Registry::Service::Stripe;

# Test the actual bug in production code
subtest 'Demonstrate async bug in Stripe Service' => sub {
    plan skip_all => "Requires STRIPE_SECRET_KEY" unless $ENV{STRIPE_SECRET_KEY} || 1; # Always run for testing

    # Set a fake API key for testing
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_fake';

    my $service = Registry::Service::Stripe->new(
        api_key => 'sk_test_fake',
    );

    # This should trigger the bug on line 44 when it tries to use start_p
    # with a transaction object
    my $promise;

    # Try to create a payment intent (this will fail due to fake key, but should
    # expose the async handling issue)
    eval {
        $promise = $service->create_payment_intent_async({
            amount => 1000,
            currency => 'usd',
            description => 'Test to expose bug',
        });
    };

    if ($@) {
        diag "Error during async call: $@";
        fail "Async call failed with error: $@";
    } else {
        ok($promise, "Promise returned from async call");
        isa_ok($promise, 'Mojo::Promise', "Return value is a promise");

        # Try to wait on it (will fail with fake API key but that's ok)
        # Use catch to properly handle the rejection
        $promise->catch(sub ($err) {
            like($err, qr/Stripe/, "Error is from Stripe API, not async handling");
        })->wait;
    }
};

done_testing;