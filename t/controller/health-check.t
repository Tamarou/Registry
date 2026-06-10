#!/usr/bin/env perl
# ABOUTME: Tests for the /health readiness probe endpoint.
# ABOUTME: Verifies the endpoint performs a DB check and returns appropriate status/fields.

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;

my $test_db = Test::Registry::DB->new;
$ENV{DB_URL} = $test_db->uri;

my $t = Test::Registry::Mojo->new('Registry');

subtest 'GET /health returns 200 with db ok on healthy app' => sub {
    $t->get_ok('/health')
      ->status_is(200)
      ->json_is('/status', 'ok')
      ->json_is('/db', 'ok', 'health response includes db field')
      ->json_has('/timestamp');
};

subtest '/health requires no authentication' => sub {
    # A brand-new client with no session should still get 200
    my $t2 = Test::Registry::Mojo->new('Registry');
    $t2->get_ok('/health')
       ->status_is(200)
       ->json_is('/status', 'ok')
       ->json_is('/db', 'ok');
};

done_testing();
