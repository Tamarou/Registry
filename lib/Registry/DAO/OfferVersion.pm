# ABOUTME: One numbered version of a PriceOps offer: editable as a draft, immutable once published.
# ABOUTME: The database enforces immutability; this class only appends and publishes.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::OfferVersion :isa(Registry::DAO::Object) {
    use Carp qw( croak );
    use Scalar::Util qw( blessed );

    field $id :param :reader;
    field $offer_id :param :reader;
    field $version :param :reader;
    field $resource_id :param :reader;
    field $published_at :param :reader = undef;
    field $superseded_at :param :reader = undef;
    field $created_at :param :reader;

    sub table { 'offer_versions' }

    method is_published { defined $published_at }

    # Appends the offer's next version number as a draft.
    sub draft ( $class, $db, $offer_id, $terms ) {
        $db = $db->db if $db isa Registry::DAO;
        my $row = $db->query(
            'INSERT INTO offer_versions (offer_id, version, resource_id)
             SELECT ?, coalesce(max(version), 0) + 1, ?
               FROM offer_versions WHERE offer_id = ?
             RETURNING *',
            $offer_id, $terms->{resource_id}, $offer_id )->hash;
        return $class->new(%$row);
    }

    # Publishes this draft and supersedes the offer's current version, in one
    # transaction: an offer with two current versions is refused by the
    # database, and one with none would sell nothing.
    method publish ($db) {
        $db = $db->db if $db isa Registry::DAO;
        my $tx = $db->begin;

        # Retired first, or the one-current index refuses the publish. Only an
        # older version is retired, so publishing a stale draft over a newer
        # current version is refused by that index rather than rolling back.
        $db->query(
            'UPDATE offer_versions SET superseded_at = now()
              WHERE offer_id = ? AND version < ?
                AND published_at IS NOT NULL AND superseded_at IS NULL',
            $offer_id, $version );

        my $row = $db->query(
            'UPDATE offer_versions SET published_at = now()
              WHERE id = ? AND published_at IS NULL RETURNING *', $id )->hash
            or croak "offer $offer_id version $version is already published";

        $tx->commit;
        return blessed($self)->new(%$row);
    }
}

1;
