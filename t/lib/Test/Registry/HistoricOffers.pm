# ABOUTME: The platform's offers to tenants as signup read them before offer versions could buy a set.
# ABOUTME: For migration tests deployed to an older change, where today's PlatformTerms reads tables not yet there.
use 5.42.0;
use warnings;

package Test::Registry::HistoricOffers;

use Exporter 'import';
our @EXPORT_OK = qw( offers_to_tenants );

# offers_to_tenants($db) -> [ { name, amount_cents, fraction } ]: registry's
# current published payment-processing versions with a percentage-of-sales
# plan, priced $0, not the platform's offer to itself, cheapest first. The
# schema before offer-version-resource-set: a version names its one resource.
sub offers_to_tenants ($db) {
    return $db->query(q{
        SELECT o.name, v.price_cents AS amount_cents, p.fraction
          FROM registry.offer_versions v
          JOIN registry.offers o ON o.id = v.offer_id
          JOIN registry.resources r ON r.id = v.resource_id
          JOIN registry.offer_version_payment_plans p
            ON p.offer_version_id = v.id AND p.kind = 'percentage_of_sales'
         WHERE r.name = 'payment processing'
           AND v.published_at IS NOT NULL AND v.superseded_at IS NULL
           AND v.price_cents = 0
           AND NOT v.conditions @> '[{"kind": "holder_is_offerer"}]'
         ORDER BY p.fraction, o.name
    })->hashes->to_array;
}

1;
