# ABOUTME: DAO for magic link tokens used in passwordless login, invitations,
# ABOUTME: and email verification. Tokens are single-use with expiry enforcement.
use 5.42.0;
use Object::Pad;

class Registry::DAO::MagicLinkToken :isa(Registry::DAO::Object) {
    use Carp qw(croak);
    use Scalar::Util qw(blessed);
    use Crypt::URandom qw(urandom);
    use MIME::Base64 qw(encode_base64url);
    use Digest::SHA qw(sha256_hex);
    use DateTime;
    use DateTime::Format::Pg;

    field $id :param :reader;
    field $user_id :param :reader;
    field $token_hash :param :reader;
    field $purpose :param :reader;
    field $expires_at :param :reader;
    field $consumed_at :param :reader = undef;
    field $created_at :param :reader = undef;

    sub table { 'magic_link_tokens' }

    # Generate a new token, returning ($token_object, $plaintext_token).
    # The plaintext is shown to the user exactly once (in the email link).
    sub generate ($class, $db, $args) {
        $db = $db->db if $db isa Registry::DAO;

        my $raw_bytes  = urandom(32);
        my $plaintext  = encode_base64url($raw_bytes);
        my $hash       = sha256_hex($plaintext);
        my $expires_in = $args->{expires_in} // 24;  # hours

        my $token = $class->create($db, {
            user_id    => $args->{user_id},
            token_hash => $hash,
            purpose    => $args->{purpose},
            expires_at => \["now() + interval '1 hour' * ?", $expires_in],
        });

        return ($token, $plaintext);
    }

    # Look up a token by its plaintext value (hashes it first).
    sub find_by_plaintext ($class, $db, $plaintext) {
        my $hash = sha256_hex($plaintext);
        return $class->find($db, { token_hash => $hash });
    }

    method is_expired () {
        return 1 unless $expires_at;
        my $exp = DateTime::Format::Pg->parse_timestamptz($expires_at);
        return $exp < DateTime->now(time_zone => 'UTC');
    }

    method consume ($db) {
        croak "Token already consumed" if $consumed_at;
        croak "Token has expired" if $self->is_expired;

        $db = $db->db if $db isa Registry::DAO;

        # Atomic conditional UPDATE prevents double-consumption under concurrency
        my $result = $db->update(
            $self->table,
            { consumed_at => \'now()' },
            { id => $id, consumed_at => undef },
            { returning => '*' }
        )->expand->hash;

        croak "Token already consumed" unless $result;

        return blessed($self)->new($result->%*);
    }
}

1;
