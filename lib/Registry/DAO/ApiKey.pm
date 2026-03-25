# ABOUTME: DAO for API bearer tokens. Generates keys with one-time plaintext
# ABOUTME: reveal, stores SHA-256 hash, and checks scope bitvectors.
use 5.42.0;
use utf8;
use Object::Pad;

class Registry::DAO::ApiKey :isa(Registry::DAO::Object) {
    use Carp qw(croak);
    use Crypt::URandom qw(urandom);
    use MIME::Base64 qw(encode_base64url);
    use Digest::SHA qw(sha256_hex);
    use DateTime;
    use DateTime::Format::Pg;

    field $id :param :reader;
    field $user_id :param :reader;
    field $key_hash :param :reader;
    field $key_prefix :param :reader;
    field $name :param :reader;
    field $scopes :param :reader = 0;
    field $expires_at :param :reader = undef;
    field $last_used_at :param :reader = undef;
    field $created_at :param :reader = undef;

    sub table { 'api_keys' }

    # Generate a new API key, returning ($key_object, $plaintext_key).
    # The plaintext is shown exactly once — it is never stored, only its hash.
    sub generate ($class, $db, $args) {
        $db = $db->db if $db isa Registry::DAO;

        my $raw_bytes = urandom(32);
        my $encoded   = encode_base64url($raw_bytes);
        my $env       = $ENV{REGISTRY_ENV} // 'live';
        my $plaintext = "rk_${env}_${encoded}";
        my $hash      = sha256_hex($plaintext);
        my $prefix    = substr($plaintext, 0, 8);

        my %create_data = (
            user_id    => $args->{user_id},
            key_hash   => $hash,
            key_prefix => $prefix,
            name       => $args->{name},
            scopes     => $args->{scopes} // 0,
        );

        if (defined $args->{expires_in}) {
            $create_data{expires_at} = \["now() + interval '1 hour' * ?", $args->{expires_in}];
        }

        my $key = $class->create($db, \%create_data);
        return ($key, $plaintext);
    }

    # Look up a key by its plaintext value (hashes it first for comparison).
    sub find_by_plaintext ($class, $db, $plaintext) {
        my $hash = sha256_hex($plaintext);
        return $class->find($db, { key_hash => $hash });
    }

    # Check whether this key grants a specific scope bit.
    # A scopes value of 0 means unrestricted (all scopes allowed).
    method has_scope ($required_scope) {
        return 1 if $scopes == 0;
        return ($scopes & $required_scope) == $required_scope;
    }

    method is_expired () {
        return 0 unless $expires_at;
        my $exp = DateTime::Format::Pg->parse_timestamptz($expires_at);
        return $exp < DateTime->now(time_zone => 'UTC');
    }

    # Record that this key was used, returning the updated key object.
    method touch ($db) {
        $db = $db->db if $db isa Registry::DAO;
        return $self->update($db, { last_used_at => \'now()' });
    }
}

1;
