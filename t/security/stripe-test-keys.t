#!/usr/bin/env perl
# ABOUTME: Tests that a live Stripe key (sk_live_) is refused outside production.
# ABOUTME: Guards dev/test environments that inherit a live key from the shell.

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;

# Build the Stripe client in a child process so each case gets a clean,
# fully-controlled environment (the parent shell may export a real live key).
# Single-quoted here-string: $vars below are literal, evaluated by the child.
my $build_client = 'require Registry::DAO::Payment;'
    . 'my $p = Registry::DAO::Payment->new;'
    . 'my $ok = eval { $p->stripe_client; 1 };'
    . 'print $ok ? "OK\n" : "ERR: $@";';

subtest 'live key outside production is refused' => sub {
    local $ENV{STRIPE_SECRET_KEY} = 'sk_live_fake_for_guard_test';
    delete local $ENV{MOJO_MODE};

    my $out = `carton exec perl -Ilib -e '$build_client' 2>&1`;
    like $out, qr/Refusing to use a live Stripe key/,
        'sk_live_ with no MOJO_MODE is refused';
    like $out, qr/sk_test_/, 'error message points at the test-key fix';
};

subtest 'live key in development mode is refused' => sub {
    local $ENV{STRIPE_SECRET_KEY} = 'sk_live_fake_for_guard_test';
    local $ENV{MOJO_MODE} = 'development';

    my $out = `carton exec perl -Ilib -e '$build_client' 2>&1`;
    like $out, qr/Refusing to use a live Stripe key/,
        'sk_live_ with MOJO_MODE=development is refused';
};

subtest 'test key outside production is allowed' => sub {
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_fake_for_guard_test';
    delete local $ENV{MOJO_MODE};

    my $out = `carton exec perl -Ilib -e '$build_client' 2>&1`;
    unlike $out, qr/Refusing to use a live Stripe key/,
        'sk_test_ key passes the live-key guard';
};

subtest 'live key in production mode is allowed past the guard' => sub {
    local $ENV{STRIPE_SECRET_KEY} = 'sk_live_fake_for_guard_test';
    local $ENV{MOJO_MODE} = 'production';

    my $out = `carton exec perl -Ilib -e '$build_client' 2>&1`;
    unlike $out, qr/Refusing to use a live Stripe key/,
        'sk_live_ with MOJO_MODE=production is permitted';
};

subtest 'CI does not export a placeholder that looks like a usable test key' => sub {
    # Test::Registry::StripeConnect::available() gates t/stripe-live/ on the
    # sk_test_ prefix alone, and ci.yml runs `prove -lr t/`, which includes
    # those files.  A placeholder starting with sk_test_ therefore convinces the
    # live suite that Stripe is reachable, and it fails against the real API on
    # every push.  Whatever CI exports must not wear that prefix.
    open my $fh, '<', '.github/workflows/ci.yml'
        or plan skip_all => "cannot read ci.yml: $!";
    my @offending = grep { /STRIPE_SECRET_KEY=sk_test_/ } <$fh>;
    close $fh;

    is scalar @offending, 0,
        'ci.yml exports no sk_test_-prefixed placeholder'
        or diag "offending lines:\n@offending";
};

done_testing;
