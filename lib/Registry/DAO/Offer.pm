# ABOUTME: A PriceOps offer: the family whose append-only versions carry a tenant's terms.
# ABOUTME: New terms are a new draft version; publishing it supersedes the current one.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::Offer :isa(Registry::DAO::Object) {
    use Registry::DAO::OfferVersion;

    field $id :param :reader;
    field $name :param :reader;
    field $created_at :param :reader;

    sub table { 'offers' }

    method draft ( $db, $terms ) {
        return Registry::DAO::OfferVersion->draft( $db, $id, $terms );
    }

    # The published, unsuperseded version, or undef while only drafts exist.
    method current_version ($db) {
        return scalar Registry::DAO::OfferVersion->find( $db,
            { offer_id => $id, published_at => { '!=' => undef }, superseded_at => undef } );
    }

    # Every version, drafts included, oldest first.
    method versions ($db) {
        return [ Registry::DAO::OfferVersion->find( $db, { offer_id => $id }, { -asc => 'version' } ) ];
    }
}

1;
