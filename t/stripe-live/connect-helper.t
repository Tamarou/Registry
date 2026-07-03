#!/usr/bin/env perl
# ABOUTME: Self-test for Test::Registry::StripeConnect: account creation, polling, caching, and unready state.
# ABOUTME: Skips entirely unless STRIPE_SECRET_KEY starts with sk_test_ -- never touches live Stripe.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::StripeConnect;

plan skip_all => 'STRIPE_SECRET_KEY (sk_test_) not set'
    unless Test::Registry::StripeConnect::available();

# -- ready_account: creates a charges_enabled Custom connected account ---

my $ready_id = Test::Registry::StripeConnect::ready_account();
like $ready_id, qr/^acct_/, 'ready_account returns an acct_ id';

# Verify directly via Stripe that the account is actually charges_enabled
my $acct = Test::Registry::StripeConnect::get_account($ready_id);
ok $acct->{charges_enabled}, 'direct GET /v1/accounts/{id} confirms charges_enabled true';

# Second call must return the identical id (per-process cache)
my $same_id = Test::Registry::StripeConnect::ready_account();
is $same_id, $ready_id, 'ready_account returns the cached id on repeated calls';

# -- unready_account: creates a NOT-charges_enabled account immediately ---

my $unready_id = Test::Registry::StripeConnect::unready_account();
like $unready_id, qr/^acct_/, 'unready_account returns an acct_ id';
isnt $unready_id, $ready_id, 'unready id is different from the ready id';

my $unready_acct = Test::Registry::StripeConnect::get_account($unready_id);
ok !$unready_acct->{charges_enabled}, 'unready account has charges_enabled false';

done_testing;
