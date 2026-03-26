# ABOUTME: Parses the WebAuthn authenticator data binary structure into its
# ABOUTME: component fields: rpIdHash, flags, signCount, and attested credential data.
use 5.42.0;
use Object::Pad;

class Registry::Auth::WebAuthn::AuthenticatorData {
    use Carp qw(croak);

    field $rp_id_hash :param :reader;
    field $flags_byte :param :reader;
    field $sign_count :param :reader;
    field $aaguid :param :reader = undef;
    field $credential_id :param :reader = undef;
    field $credential_public_key :param :reader = undef;

    use constant UP_BIT => 0x01;
    use constant UV_BIT => 0x04;
    use constant AT_BIT => 0x40;
    use constant ED_BIT => 0x80;

    sub parse ($class, $bytes) {
        croak "Authenticator data too short (need >= 37 bytes, got " . length($bytes) . ")"
            if length($bytes) < 37;

        my $rp_id_hash = substr($bytes, 0, 32);
        my $flags_byte = unpack('C', substr($bytes, 32, 1));
        my $sign_count = unpack('N', substr($bytes, 33, 4));

        my %args = (
            rp_id_hash => $rp_id_hash,
            flags_byte => $flags_byte,
            sign_count => $sign_count,
        );

        if (($flags_byte & AT_BIT) && length($bytes) > 37) {
            croak "AT flag set but data too short for attested credential"
                if length($bytes) < 55;

            $args{aaguid} = substr($bytes, 37, 16);
            my $cred_id_len = unpack('n', substr($bytes, 53, 2));

            croak "Data too short for credential ID"
                if length($bytes) < 55 + $cred_id_len;

            $args{credential_id} = substr($bytes, 55, $cred_id_len);
            $args{credential_public_key} = substr($bytes, 55 + $cred_id_len);
        }

        return $class->new(%args);
    }

    method user_present ()                  { $flags_byte & UP_BIT }
    method user_verified ()                 { $flags_byte & UV_BIT }
    method has_attested_credential_data ()  { $flags_byte & AT_BIT }
    method has_extension_data ()            { $flags_byte & ED_BIT }
}

1;
