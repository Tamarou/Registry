#!/usr/bin/env perl
# ABOUTME: Tests for the main WebAuthn library — registration/authentication
# ABOUTME: option generation and response verification against test vectors.
use 5.42.0;
use warnings;
use utf8;

use Test::More;
use Test::Exception;

use lib qw(lib t/lib);

use Registry::Auth::WebAuthn;
use Registry::Auth::WebAuthn::Challenge;
use Digest::SHA qw(sha256);
use MIME::Base64 qw(encode_base64url decode_base64url);
use Mojo::JSON qw(encode_json);

my $webauthn = Registry::Auth::WebAuthn->new(
    rp_id   => 'example.com',
    rp_name => 'Example Org',
    origin  => 'https://example.com',
);

subtest 'Generate registration options' => sub {
    my $options = $webauthn->generate_registration_options(
        'user-uuid-123',
        'testuser',
        'Test User',
    );

    ok($options, 'Got registration options');
    ok($options->{challenge}, 'Has challenge');
    is($options->{rp}{id}, 'example.com', 'Correct RP ID');
    is($options->{rp}{name}, 'Example Org', 'Correct RP name');
    is($options->{user}{id}, 'user-uuid-123', 'Correct user ID');
    is($options->{user}{name}, 'testuser', 'Correct user name');
    is($options->{user}{displayName}, 'Test User', 'Correct display name');

    is($options->{authenticatorSelection}{residentKey}, 'preferred',
        'Requests discoverable credentials');

    my @alg_ids = map { $_->{alg} } @{$options->{pubKeyCredParams}};
    ok((grep { $_ == -7 } @alg_ids), 'Supports ES256');
    ok((grep { $_ == -257 } @alg_ids), 'Supports RS256');
    ok((grep { $_ == -8 } @alg_ids), 'Supports EdDSA');
};

subtest 'Generate authentication options' => sub {
    my $options = $webauthn->generate_authentication_options();

    ok($options, 'Got authentication options');
    ok($options->{challenge}, 'Has challenge');
    is($options->{rpId}, 'example.com', 'Correct RP ID');
    is(ref $options->{allowCredentials}, 'ARRAY', 'Has allowCredentials array');
};

subtest 'Generate authentication options with credential list' => sub {
    my @cred_ids = (pack('H*', 'aabbccdd'), pack('H*', '11223344'));
    my $options = $webauthn->generate_authentication_options(
        allow_credentials => \@cred_ids,
    );

    is(scalar @{$options->{allowCredentials}}, 2, 'Two allowed credentials');
};

subtest 'Verify registration response validates origin' => sub {
    my $challenge = Registry::Auth::WebAuthn::Challenge->generate;

    my $client_data = encode_json({
        type      => 'webauthn.create',
        challenge => $challenge,
        origin    => 'https://evil.com',
    });

    dies_ok {
        $webauthn->verify_registration_response(
            $challenge,
            encode_base64url($client_data),
            encode_base64url('fake_attestation'),
        );
    } 'Rejects wrong origin';
};

subtest 'Verify registration response validates type' => sub {
    my $challenge = Registry::Auth::WebAuthn::Challenge->generate;

    my $client_data = encode_json({
        type      => 'webauthn.get',
        challenge => $challenge,
        origin    => 'https://example.com',
    });

    dies_ok {
        $webauthn->verify_registration_response(
            $challenge,
            encode_base64url($client_data),
            encode_base64url('fake_attestation'),
        );
    } 'Rejects wrong ceremony type';
};

subtest 'Verify registration response validates challenge' => sub {
    my $challenge = Registry::Auth::WebAuthn::Challenge->generate;
    my $wrong_challenge = Registry::Auth::WebAuthn::Challenge->generate;

    my $client_data = encode_json({
        type      => 'webauthn.create',
        challenge => $wrong_challenge,
        origin    => 'https://example.com',
    });

    dies_ok {
        $webauthn->verify_registration_response(
            $challenge,
            encode_base64url($client_data),
            encode_base64url('fake_attestation'),
        );
    } 'Rejects challenge mismatch';
};

subtest 'Verify authentication response validates origin' => sub {
    my $challenge = Registry::Auth::WebAuthn::Challenge->generate;

    my $client_data = encode_json({
        type      => 'webauthn.get',
        challenge => $challenge,
        origin    => 'https://evil.com',
    });

    dies_ok {
        $webauthn->verify_authentication_response(
            $challenge,
            encode_base64url($client_data),
            'fake_auth_data',
            'fake_signature',
            undef,
            0,
        );
    } 'Rejects wrong origin for authentication';
};

done_testing();
