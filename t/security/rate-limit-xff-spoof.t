# ABOUTME: Tests that rate-limit key uses connection peer address, not X-Forwarded-For.
# ABOUTME: Proves header spoofing does not allow a single client to reset its rate-limit counter.

use 5.42.0;
use FindBin qw($Bin);
use lib "$Bin/../../lib", "$Bin/../lib", "lib", "t/lib";
use experimental qw(defer);
use Test::More import => [qw( done_testing is isnt ok plan subtest )];
defer { done_testing };

use Registry::Middleware::RateLimit;

# _request_key must return the connection remote_address, never the raw
# X-Forwarded-For header.  Two requests with different XFF headers but the
# same connection peer share ONE counter.  Spoofing the header must not
# produce a fresh counter per request.

subtest 'X-Forwarded-For spoofing does not produce independent keys' => sub {
    # Build two minimal fake Mojolicious controller objects whose connection
    # peer address is the same but whose X-Forwarded-For differs.  Under the
    # old code _request_key would return different IPs (two separate counters),
    # defeating the limit.  Under the fixed code both return the same key.

    # Minimal stub for Mojo::Message::Request headers
    package Fake::Headers;
    sub new { bless {}, shift }
    sub header { undef }    # never return a value from X-Forwarded-For

    package Fake::Request;
    sub new { bless {}, shift }
    sub headers { Fake::Headers->new }

    # Minimal stub for Mojo::Transaction
    package Fake::Tx;
    sub new { my ($class, %args) = @_; bless { remote_address => $args{remote_address} }, $class }
    sub remote_address { $_[0]->{remote_address} }

    # Minimal stub for a Mojolicious controller
    package Fake::Controller;
    sub new { my ($class, %args) = @_; bless \%args, $class }
    sub req { Fake::Request->new }
    sub tx  { Fake::Tx->new(remote_address => $_[0]->{remote_address}) }

    package main;

    my $rl = Registry::Middleware::RateLimit->new;

    # Two controllers: same connection peer, different X-Forwarded-For (simulating
    # spoofed headers from the same physical connection).
    my $c1 = Fake::Controller->new(remote_address => '192.0.2.1');
    my $c2 = Fake::Controller->new(remote_address => '192.0.2.1');

    my $key1 = $rl->_request_key($c1);
    my $key2 = $rl->_request_key($c2);

    is $key1, $key2, 'same peer address produces the same rate-limit key regardless of XFF header';
};

subtest 'Spoofing X-Forwarded-For does not reset the auth-endpoint counter' => sub {
    # Exhaust the auth limit for a connection using one XFF value, then send
    # a request with a *different* XFF value on the same connection peer.
    # The counter must be shared.  A spoofed header must NOT give a fresh budget.

    # A controller stub where req->headers->header('X-Forwarded-For') returns
    # a caller-supplied value while tx->remote_address is fixed.
    package Fake::SpoofHeaders;
    sub new { my ($class, %args) = @_; bless \%args, $class }
    sub header {
        my ($self, $name) = @_;
        return $self->{xff} if lc($name) eq 'x-forwarded-for';
        return undef;
    }

    package Fake::SpoofRequest;
    sub new { my ($class, %args) = @_; bless \%args, $class }
    sub headers { Fake::SpoofHeaders->new(xff => $_[0]->{xff}) }

    package Fake::SpoofController;
    sub new { my ($class, %args) = @_; bless \%args, $class }
    sub req { Fake::SpoofRequest->new(xff => $_[0]->{xff}) }
    sub tx  { Fake::Tx->new(remote_address => '10.0.1.1') }

    package main;

    my $rl = Registry::Middleware::RateLimit->new;

    # Exhaust the AUTH limit (10) using requests that rotate the XFF header.
    # All requests come from the same connection peer (10.0.1.1).
    for my $i (1..10) {
        my $c = Fake::SpoofController->new(xff => "1.2.3.$i");
        my $key = $rl->_request_key($c);
        $rl->check($key, $Registry::Middleware::RateLimit::AUTH_LIMIT);
    }

    # The 11th request with yet another spoofed XFF must still be blocked.
    my $c11 = Fake::SpoofController->new(xff => '9.9.9.9');
    my $key  = $rl->_request_key($c11);
    my %res  = $rl->check($key, $Registry::Middleware::RateLimit::AUTH_LIMIT);

    ok !$res{allowed},
        'counter is shared across XFF values; spoofed header does not grant a fresh budget';
};
