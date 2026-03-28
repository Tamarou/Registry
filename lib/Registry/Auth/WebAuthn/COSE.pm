# ABOUTME: Parses CBOR-encoded COSE public keys from WebAuthn attestation
# ABOUTME: into Crypt::PK::* objects for signature verification (ES256, RS256, EdDSA).
use 5.42.0;
use Object::Pad;

class Registry::Auth::WebAuthn::COSE {
    use Carp qw(croak);
    use CBOR::XS qw(decode_cbor);
    use Crypt::PK::ECC;
    use Crypt::PK::RSA;
    use Crypt::PK::Ed25519;

    use constant ALG_ES256 => -7;
    use constant ALG_RS256 => -257;
    use constant ALG_EDDSA => -8;

    sub parse ($class, $cbor_bytes) {
        my $map = decode_cbor($cbor_bytes);
        croak "COSE key must be a map" unless ref $map eq 'HASH';

        my $alg = $map->{3} // croak "COSE key missing algorithm (label 3)";

        if ($alg == ALG_ES256) {
            return $class->_parse_es256($map);
        }
        elsif ($alg == ALG_RS256) {
            return $class->_parse_rs256($map);
        }
        elsif ($alg == ALG_EDDSA) {
            return $class->_parse_eddsa($map);
        }
        else {
            croak "Unsupported COSE algorithm: $alg";
        }
    }

    sub _parse_es256 ($class, $map) {
        my $x = $map->{-2} // croak "ES256 COSE key missing x coordinate";
        my $y = $map->{-3} // croak "ES256 COSE key missing y coordinate";

        my $pk = Crypt::PK::ECC->new;
        $pk->import_key_raw("\x04" . $x . $y, 'secp256r1');

        return { algorithm => 'ES256', public_key => $pk };
    }

    sub _parse_rs256 ($class, $map) {
        my $n = $map->{-1} // croak "RS256 COSE key missing modulus";
        my $e = $map->{-2} // croak "RS256 COSE key missing exponent";

        my $pk = Crypt::PK::RSA->new;
        $pk->import_key({
            N => unpack('H*', $n),
            e => unpack('H*', $e),
        });

        return { algorithm => 'RS256', public_key => $pk };
    }

    sub _parse_eddsa ($class, $map) {
        my $x = $map->{-2} // croak "EdDSA COSE key missing public key point";

        my $pk = Crypt::PK::Ed25519->new;
        $pk->import_key_raw($x, 'public');

        return { algorithm => 'EdDSA', public_key => $pk };
    }
}

1;
