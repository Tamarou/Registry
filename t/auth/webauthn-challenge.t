#!/usr/bin/env perl
# ABOUTME: Tests for WebAuthn challenge generation — randomness, encoding,
# ABOUTME: and base64url round-trip correctness.
use 5.42.0;
use warnings;
use utf8;

use Test::More;

use lib qw(lib t/lib);

use Registry::Auth::WebAuthn::Challenge;
use MIME::Base64 qw(decode_base64url);

subtest 'Generate produces base64url string' => sub {
    my $challenge = Registry::Auth::WebAuthn::Challenge->generate;
    ok($challenge, 'Generated a challenge');
    ok(length($challenge) >= 40, 'Challenge has sufficient length (32 bytes base64url)');
    like($challenge, qr/^[A-Za-z0-9_-]+$/, 'Challenge is valid base64url');
};

subtest 'Each challenge is unique' => sub {
    my %seen;
    for (1..20) {
        my $c = Registry::Auth::WebAuthn::Challenge->generate;
        $seen{$c}++;
    }
    is(scalar keys %seen, 20, 'All 20 challenges are unique');
};

subtest 'Decode round-trips correctly' => sub {
    my $challenge = Registry::Auth::WebAuthn::Challenge->generate;
    my $decoded = Registry::Auth::WebAuthn::Challenge->decode($challenge);
    is(length($decoded), 32, 'Decoded challenge is 32 raw bytes');
};

done_testing();
