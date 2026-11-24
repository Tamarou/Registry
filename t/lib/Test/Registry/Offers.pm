# ABOUTME: Test helper giving a complete, valid set of day-one offer version terms.
# ABOUTME: Tests override only the terms they are about, so each states its subject and nothing else.
use 5.42.0;
use warnings;

package Test::Registry::Offers;

use Exporter 'import';
our @EXPORT_OK = qw( offer_terms );

# offer_terms($resource_id, %overrides): terms OfferVersion->draft accepts.
sub offer_terms ( $resource_id, %overrides ) {
    return {
        resource_id          => $resource_id,
        price_cents          => 2000,
        units_per_acceptance => 1,
        per_booking_cap      => 1,
        %overrides,
    };
}

1;
