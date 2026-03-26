# ABOUTME: WebAuthn Level 2 implementation for passkey registration and
# ABOUTME: authentication. Supports ES256, RS256, and EdDSA algorithms.
use 5.42.0;
use Object::Pad;

class Registry::Auth::WebAuthn {
    use Carp qw(croak);
    use Mojo::JSON qw(decode_json);
    use MIME::Base64 qw(encode_base64url decode_base64url);
    use Digest::SHA qw(sha256);
    use CBOR::XS qw(decode_cbor);

    use Registry::Auth::WebAuthn::Challenge;
    use Registry::Auth::WebAuthn::COSE;
    use Registry::Auth::WebAuthn::AuthenticatorData;

    field $rp_id :param :reader;
    field $rp_name :param :reader;
    field $origin :param :reader;

    method generate_registration_options ($user_id, $user_name, $user_display_name, %opts) {
        my $challenge = Registry::Auth::WebAuthn::Challenge->generate;

        return {
            challenge => $challenge,
            rp        => {
                id   => $rp_id,
                name => $rp_name,
            },
            user => {
                id          => $user_id,
                name        => $user_name,
                displayName => $user_display_name,
            },
            pubKeyCredParams => [
                { type => 'public-key', alg => -7 },
                { type => 'public-key', alg => -257 },
                { type => 'public-key', alg => -8 },
            ],
            authenticatorSelection => {
                residentKey      => 'preferred',
                userVerification => 'preferred',
            },
            timeout     => 60000,
            attestation => 'none',
            %{ $opts{exclude_credentials} ? {
                excludeCredentials => [
                    map { { type => 'public-key', id => encode_base64url($_) } }
                    @{$opts{exclude_credentials}}
                ]
            } : {} },
        };
    }

    method generate_authentication_options (%opts) {
        my $challenge = Registry::Auth::WebAuthn::Challenge->generate;

        my @allow_creds;
        if ($opts{allow_credentials}) {
            @allow_creds = map {
                { type => 'public-key', id => encode_base64url($_) }
            } @{$opts{allow_credentials}};
        }

        return {
            challenge        => $challenge,
            rpId             => $rp_id,
            allowCredentials => \@allow_creds,
            userVerification => 'preferred',
            timeout          => 60000,
        };
    }

    method verify_registration_response ($expected_challenge, $client_data_b64, $attestation_object_b64) {
        my $client_data_json = decode_base64url($client_data_b64);
        my $client_data = decode_json($client_data_json);

        croak "Wrong ceremony type: expected webauthn.create, got $client_data->{type}"
            unless $client_data->{type} eq 'webauthn.create';

        croak "Origin mismatch: expected $origin, got $client_data->{origin}"
            unless $client_data->{origin} eq $origin;

        croak "Challenge mismatch"
            unless $client_data->{challenge} eq $expected_challenge;

        my $att_obj_bytes = decode_base64url($attestation_object_b64);
        my $att_obj = decode_cbor($att_obj_bytes);

        my $auth_data = Registry::Auth::WebAuthn::AuthenticatorData->parse(
            $att_obj->{authData}
        );

        my $expected_rp_hash = sha256($rp_id);
        croak "RP ID hash mismatch"
            unless $auth_data->rp_id_hash eq $expected_rp_hash;

        croak "User not present" unless $auth_data->user_present;

        croak "No attested credential data in registration response"
            unless $auth_data->has_attested_credential_data;

        return {
            credential_id => $auth_data->credential_id,
            public_key    => $auth_data->credential_public_key,
            sign_count    => $auth_data->sign_count,
        };
    }

    method verify_authentication_response (
        $expected_challenge, $client_data_b64, $authenticator_data_bytes,
        $signature, $credential_public_key_cbor, $stored_sign_count
    ) {
        my $client_data_json = decode_base64url($client_data_b64);
        my $client_data = decode_json($client_data_json);

        croak "Wrong ceremony type: expected webauthn.get, got $client_data->{type}"
            unless $client_data->{type} eq 'webauthn.get';

        croak "Origin mismatch: expected $origin, got $client_data->{origin}"
            unless $client_data->{origin} eq $origin;

        croak "Challenge mismatch"
            unless $client_data->{challenge} eq $expected_challenge;

        my $auth_data = Registry::Auth::WebAuthn::AuthenticatorData->parse(
            $authenticator_data_bytes
        );

        my $expected_rp_hash = sha256($rp_id);
        croak "RP ID hash mismatch"
            unless $auth_data->rp_id_hash eq $expected_rp_hash;

        croak "User not present" unless $auth_data->user_present;

        if ($stored_sign_count > 0 && $auth_data->sign_count <= $stored_sign_count) {
            croak "Sign count regression: stored=$stored_sign_count, received="
                . $auth_data->sign_count . " (possible cloned authenticator)";
        }

        my $signed_data = $authenticator_data_bytes . sha256($client_data_json);

        my $cose_result = Registry::Auth::WebAuthn::COSE->parse($credential_public_key_cbor);
        my $pk  = $cose_result->{public_key};
        my $alg = $cose_result->{algorithm};

        my $valid;
        if ($alg eq 'ES256') {
            $valid = $pk->verify_message_rfc7518($signature, $signed_data, 'SHA256');
        }
        elsif ($alg eq 'RS256') {
            $valid = $pk->verify_message($signature, $signed_data, 'SHA256', 'v1.5');
        }
        elsif ($alg eq 'EdDSA') {
            $valid = $pk->verify_message($signature, $signed_data);
        }
        else {
            croak "Unsupported algorithm for verification: $alg";
        }

        croak "Signature verification failed" unless $valid;

        return { sign_count => $auth_data->sign_count };
    }
}

1;
