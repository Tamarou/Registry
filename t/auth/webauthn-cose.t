#!/usr/bin/env perl
# ABOUTME: Tests for COSE key parsing — decoding CBOR-encoded public keys
# ABOUTME: into Crypt::PK::* objects for ES256, RS256, and EdDSA algorithms.
use 5.42.0;
use warnings;
use utf8;

use Test::More;
use Test::Exception;

use lib qw(lib t/lib);

use Registry::Auth::WebAuthn::COSE;
use CBOR::XS qw(encode_cbor);

subtest 'Parse ES256 (P-256 ECDSA) COSE key' => sub {
    use Crypt::PK::ECC;
    my $ec = Crypt::PK::ECC->new;
    $ec->generate_key('secp256r1');
    my $pub_raw = $ec->export_key_raw('public');  # 65 bytes: 0x04 + x + y
    my $x = substr($pub_raw, 1, 32);
    my $y = substr($pub_raw, 33, 32);

    my $cose_cbor = encode_cbor({
        1  => 2,     # kty: EC2
        3  => -7,    # alg: ES256
        -1 => 1,     # crv: P-256
        -2 => $x,    # x coordinate
        -3 => $y,    # y coordinate
    });

    my $result = Registry::Auth::WebAuthn::COSE->parse($cose_cbor);

    ok($result, 'Parsed ES256 COSE key');
    is($result->{algorithm}, 'ES256', 'Correct algorithm');
    ok($result->{public_key}, 'Has public key object');
};

subtest 'Parse RS256 (RSA) COSE key' => sub {
    use Crypt::PK::RSA;
    my $rsa = Crypt::PK::RSA->new;
    $rsa->generate_key(256, 65537);  # 256 bytes = 2048-bit key
    my $key_hash = $rsa->key2hash;
    my $n = pack('H*', $key_hash->{N});
    my $e = pack('H*', $key_hash->{e});

    my $cose_cbor = encode_cbor({
        1  => 3,      # kty: RSA
        3  => -257,   # alg: RS256
        -1 => $n,     # modulus
        -2 => $e,     # exponent
    });

    my $result = Registry::Auth::WebAuthn::COSE->parse($cose_cbor);

    ok($result, 'Parsed RS256 COSE key');
    is($result->{algorithm}, 'RS256', 'Correct algorithm');
    ok($result->{public_key}, 'Has public key object');
};

subtest 'Parse EdDSA (Ed25519) COSE key' => sub {
    use Crypt::PK::Ed25519;
    my $ed = Crypt::PK::Ed25519->new;
    $ed->generate_key;
    my $pubkey_raw = $ed->export_key_raw('public');

    my $cose_cbor = encode_cbor({
        1  => 1,     # kty: OKP
        3  => -8,    # alg: EdDSA
        -1 => 6,     # crv: Ed25519
        -2 => $pubkey_raw,
    });

    my $result = Registry::Auth::WebAuthn::COSE->parse($cose_cbor);

    ok($result, 'Parsed EdDSA COSE key');
    is($result->{algorithm}, 'EdDSA', 'Correct algorithm');
    ok($result->{public_key}, 'Has public key object');
};

subtest 'Reject unsupported algorithm' => sub {
    my $cose_cbor = encode_cbor({
        1 => 2,
        3 => -999,
    });

    dies_ok {
        Registry::Auth::WebAuthn::COSE->parse($cose_cbor);
    } 'Rejects unsupported COSE algorithm';
};

done_testing();
