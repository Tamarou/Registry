#!/usr/bin/env perl
# ABOUTME: Asserts Registry::DAO::Subscription reaches Stripe through Registry::Service::Stripe.
# ABOUTME: A second HTTP client would duplicate the API pin, the timeouts and the auth header.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Mojo::Promise;

use Registry::DAO::Subscription;
use Registry::Service::Stripe;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_layer_not_a_real_key';

my $dao = Registry::DAO::Subscription->new( db => undef );

# The API version, the timeouts and the auth header are decisions that belong
# in one place. Subscription used to carry its own Mojo::UserAgent and keep
# them in step with Service::Stripe's by hand, with comments saying so.
subtest 'Stripe I/O goes through the service layer' => sub {
    isa_ok $dao->stripe, 'Registry::Service::Stripe',
        'the DAO holds a service client';

    ok !$dao->can('_stripe_request'),
        'no second request path of its own';
};

# The webhook settles inside a database transaction. A blocking Stripe call
# there holds the dedup claim open for the length of the round trip, so every
# call this DAO makes has to be awaitable by the caller instead.
subtest 'the Stripe-calling methods are async' => sub {
    for my $method (
        qw( get_subscription_async create_customer_async
            create_setup_intent_async get_setup_intent_async
            create_subscription_with_config_async cancel_subscription_async )
      )
    {
        ok $dao->can($method), "$method exists";
    }
};

done_testing;
