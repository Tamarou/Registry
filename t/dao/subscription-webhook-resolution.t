#!/usr/bin/env perl
# ABOUTME: An invoice event whose subscription cannot be resolved must fail loudly.
# ABOUTME: Silently returning marks it processed forever, so the tenant never changes state.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Subscription;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_subscription_resolution';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $subs = Registry::DAO::Subscription->new( db => $dao );

# Newer Stripe API versions moved the subscription id to
# invoice.parent.subscription_details.subscription, so an invoice event with no
# top-level `subscription` is the routine case rather than an exotic one. The
# old code read an undef tenant_id off an undef subscription -- Perl's rvalue
# deref does not die -- fell out of `return unless $tenant_id`, and let the
# caller stamp the event processed and COMMIT. Every retry then hit the dedup
# claim, so the tenant was never moved, permanently and silently.
subtest 'an invoice with no resolvable subscription dies rather than no-opping' => sub {
    for my $handler (qw( _handle_payment_failed _handle_payment_succeeded )) {
        my $err = do {
            local $@;
            eval { $subs->$handler( $db, { object => { id => 'in_no_sub' } } ) };
            $@;
        };
        like $err, qr/Cannot resolve subscription/,
            "$handler refuses an invoice with no subscription id";
        like $err, qr/no subscription id on the invoice/,
            "$handler says which half of the lookup failed";
    }
};

# The blocking Stripe call in these handlers can run inside the webhook's
# settlement transaction via the //= fallback, holding the dedup claim open for
# its duration. Registry::Service::Stripe sets both timeouts; this client had
# neither, so the claim could be held for an unbounded wait.
subtest 'the Stripe user agent is bounded' => sub {
    my $ua = $subs->ua;
    ok $ua->connect_timeout > 0, 'connect_timeout is set';
    ok $ua->request_timeout > 0, 'request_timeout is set';
};

done_testing;
