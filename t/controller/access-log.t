#!/usr/bin/env perl
# ABOUTME: The per-request access log line: one per request, with context, and no credentials in it.
# ABOUTME: GET /auth/magic/:token carries a token that is still redeemable, so the log must not carry it.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Mojo::JSON qw(decode_json);
use Test::Registry::Mojo;
use Test::Registry::DB;

my $tdb = Test::Registry::DB->new;
my $db  = $tdb->db;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $db } );

$t->app->log->level('debug');

# A fresh scalar AND a fresh handle per capture. Truncating the scalar behind a
# live in-memory filehandle does not move the handle's offset, so the next write
# lands past it and pads everything before it with NULs -- which silently breaks
# any per-line parse of the result.
my $buf = '';
sub capture ( $code ) {
    $buf = '';
    open my $fh, '>', \$buf or die "cannot open scalar handle: $!";
    $t->app->log->handle($fh);
    $code->();
    return $buf;
}

# The access line is the one shaped "METHOD /path STATUS DURATION".
sub access_lines () {
    return grep { ( $_->{message} // '' ) =~ m{^[A-Z]+ /\S* \d+ \S+$} }
           grep { ref $_ eq 'HASH' }
           map  { my $e = eval { decode_json($_) }; $e }
           grep { /^\{/ } split /\n/, $buf;
}

subtest 'every request leaves one correlated line' => sub {
    capture( sub { $t->get_ok('/')->status_is(200) } );

    my @lines = access_lines();
    is scalar @lines, 1, 'exactly one access line, not none and not two';
    like $lines[0]{message}, qr{^GET / \d+ \d+ms$},
        'method, path, status, and how long it took';
    ok exists $lines[0]{request_id}, 'carrying the request_id that ties it to the rest of the request';
    ok exists $lines[0]{tenant_id},  'and the tenant';
};

subtest 'a token in the path is not written to the log' => sub {
    # Not a valid token -- validity is irrelevant, the route captures :token
    # either way, and what is under test is whether the captured value reaches
    # the log. A real one would still be redeemable at this point: the GET only
    # renders the confirmation page, and the POST that follows is what
    # establishes the session.
    my $secret = 'live-magic-token-9f3a7c21';
    capture( sub { $t->get_ok("/auth/magic/$secret") } );

    unlike $buf, qr/\Q$secret\E/,
        'the token appears nowhere in the log output';

    my @lines = access_lines();
    is scalar @lines, 1, 'the request is still logged';
    like $lines[0]{message}, qr{^GET /auth/magic/\[REDACTED\] \d+ \d+ms$},
        'with the credential masked and the route still identifiable';
};

subtest 'the journey is still legible' => sub {
    # The point of the line. A funnel needs to know which workflow and which
    # step, so the path is kept rather than reduced to the route pattern --
    # /:workflow/:run/:step would collapse every page of every funnel into one.
    capture( sub { $t->get_ok('/tenant-signup') } );

    my @lines = access_lines();
    is scalar @lines, 1, 'one line';
    like $lines[0]{message}, qr{^GET /tenant-signup \d+ \d+ms$},
        'naming the workflow the visitor is in';
};

subtest 'the health probe is not logged' => sub {
    # Render hits /health every five seconds. At debug that is the whole log,
    # and the requests somebody actually made are buried in it.
    capture( sub { $t->get_ok('/health')->status_is(200) } );
    is scalar access_lines(), 0, 'no access line for the probe';

    # And the context is still cleared, which is why this is a skipped log line
    # rather than an early return from the hook.
    capture( sub { $t->get_ok('/')->status_is(200) } );
    is scalar access_lines(), 1, 'the request after it still logs exactly once';
};

subtest 'requests that never reach a route are logged, not fatal' => sub {
    # loggable_path reads $c->match->stack, and after_dispatch runs for requests
    # that never reached a controller. A static asset is served by the static
    # dispatcher with an empty stack; an unknown path is swallowed by the
    # /:workflow catch-all and 404s from there. Asserted rather than reasoned
    # about, because a die in after_dispatch happens after the response has
    # already started going out.
    for my $case ( [ 'a static asset', '/js/components/workflow-progress.js' ],
                   [ 'an unrouted path', '/no-such-thing-here' ] ) {
        my ( $name, $url ) = @$case;
        capture( sub { $t->get_ok($url) } );

        my @lines = access_lines();
        is scalar @lines, 1, "$name is logged once";
        like $lines[0]{message}, qr{^GET \Q$url\E \d+ \S+$},
            "$name names the path it asked for";
    }
};

done_testing;
