#!/usr/bin/env perl
# ABOUTME: Tests that tenant resolver logs DB errors at ERROR level, not as schema-missing warnings.
# ABOUTME: Regression guard: missing-schema path still serves registry; DB errors are distinctly logged.

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Mojo::JSON qw(decode_json);
use Registry::Utility::Logger;

my $test_db = Test::Registry::DB->new;
$ENV{DB_URL} = $test_db->uri;

my $t = Test::Registry::Mojo->new('Registry');

# Helper: redirect app logger to a string buffer, run $cb, restore, return
# the parsed JSON log entries emitted during the callback.
my sub with_captured_log ($app, $level, $cb) {
    my $buf = '';
    open my $fh, '>', \$buf or die "Cannot open log buffer: $!";
    my $logger = Registry::Utility::Logger->new(level => $level);
    $logger->handle($fh);
    my $prev_log = $app->log;
    $app->log($logger);
    eval { $cb->() };
    my $err = $@;
    $app->log($prev_log);
    close $fh;
    die $err if $err;
    return grep { defined } map { eval { decode_json($_) } } split /\n/, $buf;
}

subtest 'schema miss (subdomain, no schema) degrades to registry with a WARN' => sub {
    # Build a controller with a Host header that _extract_tenant_from_subdomain
    # will parse as slug 'ghosttenant'.  The real DB has no such schema, so the
    # query returns 0 rows and the tenant helper should:
    #   - return 'registry' (resilience)
    #   - emit a warn (not an error) with the slug name

    my @entries = with_captured_log($t->app, 'warn', sub {
        my $c = $t->app->build_controller;
        $c->req->headers->header('Host' => 'ghosttenant.localhost');
        my $result = $c->tenant;
        is $result, 'registry', 'ghost tenant degrades to registry';
    });

    my @miss_warns = grep {
        defined $_->{message}
        && $_->{message} =~ /ghosttenant/i
    } @entries;

    ok scalar(@miss_warns) > 0,
        'warn emitted for missing schema tenant'
        or diag "All log entries:\n" . join("\n", map { Mojo::JSON::encode_json($_) } @entries);

    my $w = $miss_warns[0];
    is $w->{level}, 'warn', 'schema-miss log is at warn level (not error)';
    unlike $w->{message}, qr/failed|error/i,
        'schema-miss message does not say "failed" or "error"';
};

subtest 'DB error during schema check is logged at ERROR level, not as schema-miss' => sub {
    # Override the dao helper to simulate a DB that throws during query execution.
    # The tenant helper must:
    #   - still return 'registry' (resilience preserved)
    #   - log at ERROR level with a message distinguishable from a schema miss

    {
        # Minimal broken DAO stubs -- these are test-only, not production code.
        package t::MockBrokenDB;
        sub query { die "simulated DB connection failure\n" }
    }
    {
        package t::MockBrokenDAO;
        sub db { bless {}, 't::MockBrokenDB' }
    }

    # Temporarily replace the 'dao' helper with one that returns the broken DAO
    my $orig_dao_helper = $t->app->renderer->helpers->{dao};
    $t->app->helper(dao => sub { bless {}, 't::MockBrokenDAO' });

    my $tenant_result;
    my @entries = with_captured_log($t->app, 'warn', sub {
        my $c = $t->app->build_controller;
        $c->req->headers->header('Host' => 'errortest.localhost');
        $tenant_result = $c->tenant;
    });

    # Restore original dao helper
    $t->app->helper(dao => $orig_dao_helper);

    is $tenant_result, 'registry',
        'DB error still degrades to registry (resilience preserved)';

    my @error_entries = grep {
        defined $_->{level} && $_->{level} eq 'error'
    } @entries;

    ok scalar(@error_entries) > 0,
        'DB error during schema check emits an ERROR-level log entry'
        or diag "All captured log entries:\n" . join("\n", map { Mojo::JSON::encode_json($_) } @entries);

    if (@error_entries) {
        like $error_entries[0]{message},
            qr/schema.existence check failed|failed.*errortest|errortest.*failed/i,
            'error message identifies the failure as a schema-check failure';
        unlike $error_entries[0]{message},
            qr/resolved but has no schema/,
            'error message does not mislabel a DB error as a missing schema';
    }
};

done_testing();
