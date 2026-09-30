# ABOUTME: Platform-level configuration Alex owns, read and written as rows rather than env vars.
# ABOUTME: NULL is "not set" -- the code default applies -- and is distinct from every value a key accepts.
use 5.42.0;
use utf8;
use Object::Pad;

class Registry::DAO::PlatformSetting :isa(Registry::DAO::Object) {
    use Carp qw( croak );

    field $key          :param :reader;
    field $value        :param :reader = undef;
    field $description  :param :reader = '';
    field $default_note :param :reader = '';
    field $updated_at   :param :reader = undef;
    field $updated_by   :param :reader = undef;

    sub table { 'platform_settings' }

    # Every key the platform knows about, seeded or set. Listed rather than
    # discovered: the point of seeding the rows is that Alex can see what exists
    # without already knowing its name.
    sub all ( $class, $db ) {
        $db = $db->db if $db isa Registry::DAO;
        return $db->query(
            'SELECT * FROM registry.platform_settings ORDER BY key'
        )->hashes->map( sub { $class->new(%$_) } )->to_array;
    }

    # The raw value, or undef for "not set". Callers turn that into their own
    # default; this does not invent one, because the default belongs to whatever
    # reads the key and is documented next to it.
    sub get ( $class, $db, $key ) {
        $db = $db->db if $db isa Registry::DAO;
        my $row = $db->query(
            'SELECT value FROM registry.platform_settings WHERE key = ?', $key )->hash;
        return undef unless $row;
        return $row->{value};
    }

    # Set a key, or unset it by passing undef.
    #
    # Refuses a key that is not seeded. A typo would otherwise create a row
    # nothing reads, which looks exactly like a setting that is not working --
    # and the seeded rows are the list of what exists.
    sub set ( $class, $db, $key, $value, $actor_id = undef ) {
        $db = $db->db if $db isa Registry::DAO;

        my $rows = $db->query( q{
            UPDATE registry.platform_settings
               SET value = ?, updated_at = now(), updated_by = ?
             WHERE key = ?
         RETURNING key
        }, $value, $actor_id, $key )->rows;

        croak "'$key' is not a platform setting" unless $rows;
        return 1;
    }
}
