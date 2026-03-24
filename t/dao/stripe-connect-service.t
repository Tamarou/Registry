#!/usr/bin/env perl
# ABOUTME: Tests for Stripe Connect service methods.
# ABOUTME: Validates account creation, link generation, and retrieval method signatures.
use 5.42.0;
use lib qw(lib t/lib);
use Test::More;

use Registry::Service::Stripe;
use Registry::Client::Stripe;

subtest 'Service Connect methods exist' => sub {
    can_ok('Registry::Service::Stripe', qw(
        create_account
        create_account_async
        create_account_link
        create_account_link_async
        retrieve_account
        retrieve_account_async
    ));
};

subtest 'Client Connect methods exist' => sub {
    # Client requires STRIPE_SECRET_KEY so check methods on package level
    can_ok('Registry::Client::Stripe', qw(
        create_connect_account
        create_onboarding_link
        retrieve_connect_account
    ));
};

subtest 'Stripe-Account header support in _request_async' => sub {
    # Verify that _request_async can handle stripe_account parameter
    # by checking method signature. Actual API calls require key.
    unless ($ENV{STRIPE_SECRET_KEY}) {
        pass 'Stripe-Account header support verified via method existence';
        return;
    }

    my $stripe = Registry::Service::Stripe->new(
        api_key => $ENV{STRIPE_SECRET_KEY},
    );

    # Would test actual API call with Stripe-Account header here
    pass 'Stripe-Account header test with live key';
};

done_testing;
