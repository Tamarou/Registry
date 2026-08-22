#!/usr/bin/env perl
# ABOUTME: The Stripe signature check accepts a header carrying more than one v1 signature.
# ABOUTME: Stripe sends both the old and new signature during endpoint-secret rotation.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Digest::SHA qw(hmac_sha256_hex);
use Registry::Controller::Webhooks;

my $ctrl    = Registry::Controller::Webhooks->new;
my $payload = '{"id":"evt_sig","type":"payment_intent.succeeded"}';
my $now     = time();

sub sig_for ($secret) { hmac_sha256_hex( "$now.$payload", $secret ) }
sub check ($header, $secret) {
    return $ctrl->_verify_stripe_signature( $payload, $header, $secret );
}

my $old = 'whsec_old_secret';
my $new = 'whsec_new_secret';

subtest 'a single signature verifies against its own secret' => sub {
    ok check( "t=$now,v1=" . sig_for($old), $old ), 'old secret, old signature';
    ok check( "t=$now,v1=" . sig_for($new), $new ), 'new secret, new signature';
    ok !check( "t=$now,v1=" . sig_for($old), $new ), 'and a wrong secret still fails';
};

# During rotation Stripe signs the payload with BOTH secrets and sends both in
# one header. Whichever secret this deployment holds must verify, regardless of
# which signature happens to be listed last -- a parser that keeps only the last
# v1 rejects live payment confirmations for the whole rotation window, and
# repeated 4xx is how Stripe disables an endpoint.
subtest 'a rotation header carrying two signatures verifies against either secret' => sub {
    my $both     = "t=$now,v1=" . sig_for($old) . ',v1=' . sig_for($new);
    my $reversed = "t=$now,v1=" . sig_for($new) . ',v1=' . sig_for($old);

    ok check( $both, $old ), 'old secret verifies when its signature is first';
    ok check( $both, $new ), 'new secret verifies when its signature is last';
    ok check( $reversed, $new ), 'new secret verifies when its signature is first';
    ok check( $reversed, $old ), 'old secret verifies when its signature is last';

    ok !check( $both, 'whsec_third_party' ),
        'and a secret matching neither is still rejected';
};

subtest 'malformed headers are rejected without warnings' => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };

    ok !check( "t=not-a-number,v1=" . sig_for($old), $old ), 'non-numeric timestamp';
    ok !check( "v1=" . sig_for($old), $old ), 'missing timestamp';
    ok !check( "t=$now", $old ), 'missing signature';
    ok !check( '', $old ), 'empty header';

    is_deeply \@warnings, [],
        'an attacker-controlled header does not leak warnings into the log';
};

# The only anti-replay control on the money endpoint, and nothing graded it --
# deleting the line entirely left the whole suite green. The change that added
# the numeric check also shifted load onto this window: t=0 used to be rejected
# by a truthiness test upstream, and now reaches here and only here.
subtest 'the replay window is enforced in both directions' => sub {
    for my $skew ( -400, -301, 301, 400 ) {
        my $t = time() + $skew;
        my $sig = hmac_sha256_hex( "$t.$payload", $old );
        ok !check( "t=$t,v1=$sig", $old ),
            "a correctly-signed payload ${skew}s away is refused";
    }
    for my $skew ( -299, 0, 299 ) {
        my $t = time() + $skew;
        my $sig = hmac_sha256_hex( "$t.$payload", $old );
        ok check( "t=$t,v1=$sig", $old ),
            "and one ${skew}s away is still accepted";
    }
};

# _secure_compare's length check is not cosmetic: the comparison loop runs
# 0 .. length($expected)-1, so without it any candidate whose PREFIX is the
# correct signature verifies. That is a forgery bypass, and no test touched it.
subtest 'a candidate that merely starts with the right signature is refused' => sub {
    my $t   = time();
    my $sig = hmac_sha256_hex( "$t.$payload", $old );

    ok check( "t=$t,v1=$sig", $old ), 'the exact signature verifies';
    ok !check( "t=$t,v1=" . $sig . ('0' x 200), $old ),
        'the signature plus trailing garbage does not';
    ok !check( "t=$t,v1=" . substr( $sig, 0, 32 ), $old ),
        'and a truncated signature does not';
};

# @v1 is attacker-supplied and was unbounded, on the one route that opts out of
# rate limiting. Stripe sends one signature normally and two during rotation.
subtest 'an absurd number of candidate signatures is refused outright' => sub {
    my $t   = time();
    my $sig = hmac_sha256_hex( "$t.$payload", $old );

    ok check( "t=$t,v1=$sig," . join( ',', map { "v1=deadbeef$_" } 1 .. 5 ), $old ),
        'a plausible handful still verifies';
    ok !check( "t=$t,v1=$sig," . join( ',', map { "v1=deadbeef$_" } 1 .. 200 ), $old ),
        'two hundred candidates are refused even though one of them is valid';
};

done_testing;
