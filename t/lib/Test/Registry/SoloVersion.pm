# ABOUTME: Publishes a later Solo version on the current one's terms and set, and has a tenant accept Solo's current version.
# ABOUTME: Solo's version buys a set, which offer-publishing cannot version, so tests publish it as solo-grants-workflow-set did.
use 5.42.0;
use warnings;

package Test::Registry::SoloVersion;

use Exporter 'import';
our @EXPORT_OK = qw( publish_solo_version accept_solo );

use Registry::DAO::Offer;
use Registry::DAO::OfferVersion;
use Registry::DAO::Tenant;
use Registry::PriceOps::PlatformTerms ();

# publish_solo_version($db, $fraction) -> the new, current Solo OfferVersion:
# the current version's set, price, units, cap and policies, with one
# revenue_share plan at $fraction.
sub publish_solo_version ( $db, $fraction ) {
    $db = $db->db if $db isa Registry::DAO;
    my $solo    = $Registry::PriceOps::PlatformTerms::SOLO_OFFER_ID;
    my $current = Registry::DAO::Offer->find( $db, { id => $solo } )->current_version($db);
    my $set     = $db->query( 'SELECT array_agg(resource_id) FROM registry.offer_version_resources
                                WHERE offer_version_id = ?', $current->id )->array->[0];
    return Registry::DAO::OfferVersion->draft( $db, $solo, {
        resource_ids  => $set,
        ( map { $_ => $current->$_ } qw( price_cents currency units_per_acceptance per_booking_cap policies ) ),
        payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => $fraction } ],
    } )->publish($db);
}

# accept_solo($db, $tenant) -> accept_platform_offer's result: $tenant accepts
# Solo's current version under its revenue-share plan, as signup does, and so
# holds the run right to every workflow Solo's set lists.
sub accept_solo ( $db, $tenant ) {
    $db = $db->db if $db isa Registry::DAO;
    my $current = Registry::DAO::Offer->find( $db, { id => $Registry::PriceOps::PlatformTerms::SOLO_OFFER_ID } )
        ->current_version($db);
    return Registry::DAO::Tenant->accept_platform_offer( $db, $tenant,
        { offer_version_id => $current->id, payment_plan_id => 'revenue_share' } );
}

1;
