#!/usr/bin/env perl
# ABOUTME: Tests that MOJO_SECRET is required in production mode.
# ABOUTME: Verifies the hostname fallback only works in development.

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;

# Each subtest forks a child process because Mojolicious apps are singletons
# and can't be re-created within the same process.

my $test_db = Test::Registry::DB->new;
$ENV{DB_URL} = $test_db->uri;

subtest 'production mode dies without MOJO_SECRET' => sub {
    delete local $ENV{MOJO_SECRET};
    local $ENV{MOJO_MODE} = 'production';

    my $output = `carton exec perl -Ilib -It/lib -e 'require Registry; Registry->new' 2>&1`;
    my $exit = $? >> 8;
    isnt $exit, 0, 'exits non-zero';
    like $output, qr/MOJO_SECRET.*required/i, 'dies with helpful message';
};

subtest 'development mode allows hostname fallback' => sub {
    delete local $ENV{MOJO_SECRET};
    local $ENV{MOJO_MODE} = 'development';

    my $output = `carton exec perl -Ilib -It/lib -e 'require Registry; Registry->new; print "OK\n"' 2>&1`;
    my $exit = $? >> 8;
    is $exit, 0, 'exits cleanly';
    like $output, qr/OK/, 'app starts successfully';
};

subtest 'MOJO_SECRET set works in production' => sub {
    local $ENV{MOJO_SECRET} = 'test-secret-value';
    local $ENV{MOJO_MODE} = 'production';

    my $output = `carton exec perl -Ilib -It/lib -e 'require Registry; Registry->new; print "OK\n"' 2>&1`;
    my $exit = $? >> 8;
    is $exit, 0, 'exits cleanly';
    like $output, qr/OK/, 'app starts with MOJO_SECRET set';
};

done_testing;
