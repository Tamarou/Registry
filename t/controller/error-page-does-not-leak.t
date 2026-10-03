#!/usr/bin/env perl
# ABOUTME: In production a die must render a generic page, not the exception and its source path.
# ABOUTME: Mojolicious picks exception.production.html.ep when it exists; without one, users get the dev view.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Test::Registry::Mojo;
use Test::Registry::DB;
use Mojo::JSON qw(decode_json);
use Registry;

my $tdb = Test::Registry::DB->new;
my $db  = $tdb->db;

# The message carries the two things that must not reach a user: an internal
# identifier and something shaped like a filesystem path.
my $MESSAGE = 'Payment 1f0e4d2c-dead-beef-cafe-0123456789ab not found';

sub app_in_mode ($mode) {
    local $ENV{MOJO_SECRET} = 'error-page-test-secret';
    my $t = Test::Registry::Mojo->new( Registry->new( mode => $mode ) );
    $t->app->helper( dao => sub { $db } );
    # The die is deliberate, so the log goes to a scalar rather than to the
    # test output -- at debug, because the access line is what the reference on
    # the page has to match.
    $t->app->log->level('debug');
    # No trailing newline, deliberately: Perl then appends " at FILE line N",
    # which is the source disclosure half of this bug. With a newline the path
    # assertions below pass against a message that never had a path in it.
    $t->app->routes->get( '/test-only/boom' => sub { die $MESSAGE } );
    return $t;
}

# The request id on the page is only useful if it is the one in the logs, and
# the id Test::Mojo's own client-side request carries is a different one.
sub request_id_from_log ($buf) {
    for my $line ( split /\n/, $buf ) {
        next unless $line =~ /^\{/;
        my $entry = eval { decode_json($line) } or next;
        return $entry->{request_id}
            if ( $entry->{message} // '' ) =~ m{^GET /test-only/boom };
    }
    return undef;
}

subtest 'production renders a generic page' => sub {
    my $t = app_in_mode('production');

    my $log = '';
    open my $fh, '>', \$log or die "cannot open scalar handle: $!";
    $t->app->log->handle($fh);

    $t->get_ok('/test-only/boom')->status_is(500);

    my $body = $t->tx->res->body;

    unlike $body, qr/\Q$MESSAGE\E/, 'the exception message is not in the page';
    unlike $body, qr/ line \d+/,     'nor the source file and line Perl appended';
    unlike $body, qr{/home/|/app/},  'nor an absolute path from the filesystem';
    unlike $body, qr/Technical Details/i, 'and no disclosure triangle inviting a look';

    like $body, qr/error/i, 'it still says something went wrong';

    # A generic page with nothing to quote makes the user describe the problem
    # instead of naming it. Asserted against the id in this request's own log
    # line, because a reference that does not match the logs is decoration.
    my $request_id = request_id_from_log($log);
    ok $request_id, 'the request was logged with an id';
    like $body, qr/\Q$request_id\E/, 'and the page quotes that same id';
};

subtest 'development still shows the details' => sub {
    # The detail view is why the bug existed: it is useful, and it was never
    # gated. Deleting it instead of gating it would be the other wrong fix.
    my $t = app_in_mode('development');
    my $log = '';
    open my $fh, '>', \$log or die "cannot open scalar handle: $!";
    $t->app->log->handle($fh);

    $t->get_ok('/test-only/boom')->status_is(500);

    like $t->tx->res->body, qr/\Q$MESSAGE\E/,
        'a developer still sees what actually happened';
};

done_testing;
