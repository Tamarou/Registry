#!/usr/bin/env perl
# ABOUTME: Tests that per-request log correlation fields (request_id, tenant_id) appear in log output.
# ABOUTME: Verifies the before_dispatch/after_dispatch hooks wire Logger::set_context correctly.

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

subtest 'JSON log lines carry request_id and tenant_id during a request' => sub {
    # Redirect the app logger to a string buffer so we can inspect output.
    my $log_buf = '';
    open my $log_fh, '>', \$log_buf or die "Cannot open string buffer: $!";

    my $logger = Registry::Utility::Logger->new(level => 'debug');
    $logger->handle($log_fh);
    $t->app->log($logger);

    # Make a request -- /health is auth-free and guaranteed to reach dispatch
    $t->get_ok('/health')->status_is(200);

    close $log_fh;

    # Parse log lines and find at least one that carries request_id
    my @lines = split /\n/, $log_buf;
    my @entries = grep { defined } map { eval { decode_json($_) } } @lines;

    ok scalar(@entries) > 0, 'logger produced at least one JSON log line';

    my @with_request_id = grep { defined $_->{request_id} } @entries;
    ok scalar(@with_request_id) > 0,
        'at least one log line carries a request_id field'
        or diag "Log output:\n$log_buf";

    my $entry = $with_request_id[0];
    ok defined($entry->{request_id}), 'request_id is defined';
    ok defined($entry->{tenant_id}),  'tenant_id is defined';
};

subtest 'context is cleared after request (no stale fields)' => sub {
    my $logger = $t->app->log;

    # After the previous request, context should be cleared
    ok $logger->can('clear_context'), 'logger has clear_context method';

    # Log a line outside of a request -- it should NOT carry request_id
    my $out_buf = '';
    open my $out_fh, '>', \$out_buf or die "Cannot open string buffer: $!";
    my $bare_logger = Registry::Utility::Logger->new(level => 'debug');
    $bare_logger->handle($out_fh);
    $bare_logger->info('outside request');
    close $out_fh;

    my ($entry) = grep { defined } map { eval { decode_json($_) } } split(/\n/, $out_buf);
    ok $entry, 'parsed log entry';
    ok !defined($entry->{request_id}), 'no request_id outside a request context'
        or diag "entry: " . encode_json($entry);
};

done_testing();
