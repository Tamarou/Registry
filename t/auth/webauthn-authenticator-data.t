#!/usr/bin/env perl
# ABOUTME: Tests for parsing the WebAuthn authenticator data binary structure:
# ABOUTME: rpIdHash, flags, signCount, and attested credential data.
use 5.42.0;
use warnings;
use utf8;

use Test::More;
use Test::Exception;

use lib qw(lib t/lib);

use Registry::Auth::WebAuthn::AuthenticatorData;
use Digest::SHA qw(sha256);

subtest 'Parse minimal authenticator data (37 bytes, no attestation)' => sub {
    my $rp_id_hash = sha256('example.com');
    my $flags      = pack('C', 0x01);  # UP bit set
    my $sign_count = pack('N', 42);

    my $auth_data_bytes = $rp_id_hash . $flags . $sign_count;

    my $parsed = Registry::Auth::WebAuthn::AuthenticatorData->parse($auth_data_bytes);

    ok($parsed, 'Parsed authenticator data');
    is($parsed->rp_id_hash, $rp_id_hash, 'Correct rpIdHash');
    is($parsed->sign_count, 42, 'Correct sign count');
    ok($parsed->user_present, 'User present flag set');
    ok(!$parsed->user_verified, 'User verified flag not set');
    ok(!$parsed->has_attested_credential_data, 'No attested credential data');
};

subtest 'Parse flags correctly' => sub {
    my $rp_id_hash = sha256('example.com');
    my $flags      = pack('C', 0b01000101);  # UP=1, UV=1, AT=1
    my $sign_count = pack('N', 0);

    my $auth_data_bytes = $rp_id_hash . $flags . $sign_count;

    my $parsed = Registry::Auth::WebAuthn::AuthenticatorData->parse($auth_data_bytes);

    ok($parsed->user_present, 'UP flag set');
    ok($parsed->user_verified, 'UV flag set');
    ok($parsed->has_attested_credential_data, 'AT flag set');
};

subtest 'Reject truncated data' => sub {
    dies_ok {
        Registry::Auth::WebAuthn::AuthenticatorData->parse('too short');
    } 'Rejects data shorter than 37 bytes';
};

subtest 'Parse with attested credential data' => sub {
    my $rp_id_hash = sha256('example.com');
    my $flags      = pack('C', 0b01000001);  # UP + AT
    my $sign_count = pack('N', 1);

    my $aaguid     = "\x00" x 16;
    my $cred_id    = 'test_credential_id_value';
    my $cred_id_len = pack('n', length($cred_id));
    my $cose_key   = pack('H*', 'a501020326200121582000000000000000000000000000000000000000000000000000000000000000002258200000000000000000000000000000000000000000000000000000000000000000');

    my $auth_data_bytes = $rp_id_hash . $flags . $sign_count
                        . $aaguid . $cred_id_len . $cred_id . $cose_key;

    my $parsed = Registry::Auth::WebAuthn::AuthenticatorData->parse($auth_data_bytes);

    ok($parsed->has_attested_credential_data, 'Has attested credential data');
    is($parsed->credential_id, $cred_id, 'Correct credential ID extracted');
    ok($parsed->credential_public_key, 'Has credential public key bytes');
    is($parsed->aaguid, $aaguid, 'Correct AAGUID');
};

done_testing();
