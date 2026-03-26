# ABOUTME: Generates cryptographic challenges for WebAuthn registration and
# ABOUTME: authentication ceremonies, with session storage helpers.
use 5.42.0;
use Object::Pad;

class Registry::Auth::WebAuthn::Challenge {
    use Crypt::URandom qw(urandom);
    use MIME::Base64 qw(encode_base64url decode_base64url);

    sub generate ($class) {
        return encode_base64url(urandom(32));
    }

    sub store ($class, $c, $challenge) {
        $c->session(webauthn_challenge => $challenge);
    }

    sub retrieve ($class, $c) {
        my $challenge = $c->session('webauthn_challenge');
        delete $c->session->{webauthn_challenge};
        return $challenge;
    }

    sub decode ($class, $challenge_b64) {
        return decode_base64url($challenge_b64);
    }
}

1;
