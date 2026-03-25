# ABOUTME: DAO for WebAuthn passkey credentials. Handles CRUD operations,
# ABOUTME: sign count tracking with replay protection, and per-user queries.
use 5.42.0;
use Object::Pad;

class Registry::DAO::Passkey :isa(Registry::DAO::Object) {
    use Carp qw(croak);

    field $id :param :reader;
    field $user_id :param :reader;
    field $credential_id :param :reader;
    field $public_key :param :reader;
    field $sign_count :param :reader = 0;
    field $device_name :param :reader = undef;
    field $created_at :param :reader = undef;
    field $last_used_at :param :reader = undef;

    sub table { 'passkeys' }

    method update_sign_count ($db, $new_count) {
        croak "Sign count regression detected (replay attack?): stored=$sign_count, received=$new_count"
            if $new_count <= $sign_count;

        $db = $db->db if $db isa Registry::DAO;

        return $self->update($db, {
            sign_count   => $new_count,
            last_used_at => \'now()',
        });
    }

    sub for_user ($class, $db, $user_id) {
        $db = $db->db if $db isa Registry::DAO;

        my @rows = $db->select('passkeys', '*', { user_id => $user_id },
            { -asc => 'created_at' })->hashes->each;

        return map { $class->new(%$_) } @rows;
    }
}

1;
