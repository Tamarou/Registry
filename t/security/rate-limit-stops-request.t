#!/usr/bin/env perl
# ABOUTME: A request past the rate limit stops at the limiter over HTTP: the client gets the
# ABOUTME: limiter's 429, the route's action never runs, and nothing else renders after it.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use experimental qw(defer signatures);
use Test::More import => [qw( done_testing is ok unlike subtest )];
defer { done_testing };

use Test::Mojo;
use Test::Registry::DB;
use Registry::DAO::WorkflowRun;
use Registry::Middleware::RateLimit;

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
$ENV{DB_URL} = $t_db->uri;
$dao->import_workflows( ['workflows/tenant-signup.yml'] );
$dao->current_tenant('registry');

# POST /tenant-signup starts a run, so a run row is proof its action ran.
sub runs () { scalar( my @r = Registry::DAO::WorkflowRun->find( $dao->db, {} ) ) }

# Everything the app logs, and anything warned, for one request.
my @log;
local $SIG{__WARN__} = sub { push @log, @_ };
sub logged_during ($t, $request) {
    @log = ();
    my $cb = $t->app->log->on( message => sub ( $, $level, @lines ) { push @log, "[$level] @lines" } );
    $request->();
    $t->app->log->unsubscribe( message => $cb );
    return join "\n", @log;
}

# Two requests per window, so the third from the same address is limited.
local $Registry::Middleware::RateLimit::GENERAL_LIMIT = 2;

my sub app ($class) {
    my $t = $class->new('Registry');
    $t->app->helper( dao => sub { $dao } );
    return $t;
}

my sub limited_ok ( $t, $label ) {
    $t->status_is( 429, "$label: 429" )
      ->header_like( 'Retry-After', qr/^\d+$/, "$label: Retry-After" )
      ->json_is( '/error', 'Rate limit exceeded. Please try again later.', "$label: the limiter's body" );
}

subtest 'a browser with a CSRF token is limited on its third request' => sub {
    my $t = app('Test::Mojo');
    my $token = $t->get_ok('/')->status_is(200)
      ->tx->res->dom->at('meta[name="csrf-token"]')->attr('content');

    my $before = runs();
    $t->post_ok( '/tenant-signup' => form => { csrf_token => $token } )
      ->status_is( 302, 'under the limit the POST works' );
    is runs(), $before + 1, 'and starts a run';

    $before = runs();
    my $log = logged_during( $t, sub { $t->post_ok( '/tenant-signup' => form => { csrf_token => $token } ) } );
    limited_ok( $t, 'past the limit' );
    is runs(), $before, 'the action never ran: no run started';
    unlike $log, qr/already been rendered/, 'nothing rendered after the limiter';
};

subtest 'a client without a CSRF token gets the 429, not a dropped connection' => sub {
    my $t = app('Test::Mojo');
    $t->get_ok('/health')->status_is(200);
    $t->get_ok('/health')->status_is(200);

    my $before = runs();
    my $log = logged_during( $t, sub { $t->post_ok('/tenant-signup') } );
    limited_ok( $t, 'past the limit' );
    is runs(), $before, 'the action never ran: no run started';
    unlike $log, qr/already been rendered/, 'nothing rendered after the limiter';
};
