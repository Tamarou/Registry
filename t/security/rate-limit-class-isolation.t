# ABOUTME: Tests that general traffic does not consume the (smaller) auth rate-limit budget.
# ABOUTME: The counter must be scoped per limit class, not shared across all paths for an IP.

use 5.42.0;
use FindBin qw($Bin);
use lib "$Bin/../../lib", "$Bin/../lib", "lib", "t/lib";
use experimental qw(defer);
use Test::More import => [qw( done_testing is ok subtest )];
defer { done_testing };

use Registry::Middleware::RateLimit;

# Minimal controller stub sufficient for before_dispatch: a path, a peer
# address, and enough of the render plumbing to observe a 429.

package Fake::Path;
sub new { my ($class, $path) = @_; bless { path => $path }, $class }
sub to_string { $_[0]->{path} }

package Fake::Url;
sub new { my ($class, $path) = @_; bless { path => Fake::Path->new($path) }, $class }
sub path { $_[0]->{path} }

package Fake::Headers;
sub new { bless {}, shift }
sub header { undef }

package Fake::Request;
sub new { my ($class, $path) = @_; bless { path => $path }, $class }
sub url { Fake::Url->new( $_[0]->{path} ) }
sub headers { Fake::Headers->new }

package Fake::ResHeaders;
sub new { bless {}, shift }
sub header { }

package Fake::Response;
sub new { bless {}, shift }
sub headers { Fake::ResHeaders->new }

package Fake::Tx;
sub new { my ($class, $ip) = @_; bless { ip => $ip }, $class }
sub remote_address { $_[0]->{ip} }

package Fake::Controller;
sub new {
    my ($class, %args) = @_;
    bless { %args, rendered_status => undef }, $class;
}
sub req { Fake::Request->new( $_[0]->{path} ) }
sub tx  { Fake::Tx->new( $_[0]->{ip} ) }
sub res { Fake::Response->new }
sub render   { my ($self, %args) = @_; $self->{rendered_status} = $args{status}; }
sub rendered { my ($self, $status) = @_; $self->{rendered_status} //= $status; }
sub was_limited { ($_[0]->{rendered_status} // 0) == 429 }

package main;

# Drive a request through the real before_dispatch hook and report whether
# it was rejected with a 429.
sub request_limited ($rl, $ip, $path) {
    my $c = Fake::Controller->new( ip => $ip, path => $path );
    $rl->before_dispatch($c);
    return $c->was_limited;
}

subtest 'general traffic does not consume the auth budget' => sub {
    my $rl = Registry::Middleware::RateLimit->new;

    # 20 ordinary page requests from one client: legitimate browsing, well
    # under the general limit of 100.
    for my $i (1 .. 20) {
        ok !request_limited($rl, '198.51.100.7', '/programs/some-page'),
            "general request $i is allowed";
    }

    # The client now tries to log in.  The auth limit (10) must apply to AUTH
    # traffic only; the 20 general requests must not have consumed it.
    ok !request_limited($rl, '198.51.100.7', '/auth/magic/request'),
        'auth request after heavy general browsing is still allowed';
};

subtest 'auth budget is still enforced independently' => sub {
    my $rl = Registry::Middleware::RateLimit->new;

    for my $i (1 .. $Registry::Middleware::RateLimit::AUTH_LIMIT) {
        ok !request_limited($rl, '198.51.100.8', '/auth/magic/request'),
            "auth request $i within the limit is allowed";
    }

    ok request_limited($rl, '198.51.100.8', '/auth/magic/request'),
        'auth request beyond the limit is rejected';

    # Exhausting the auth budget must not block ordinary browsing.
    ok !request_limited($rl, '198.51.100.8', '/programs/some-page'),
        'general request is unaffected by an exhausted auth budget';
};
