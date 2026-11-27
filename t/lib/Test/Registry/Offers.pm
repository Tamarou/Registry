# ABOUTME: Test helper giving a complete, valid set of day-one offer version terms.
# ABOUTME: Tests override only the terms they are about, so each states its subject and nothing else.
use 5.42.0;
use warnings;

package Test::Registry::Offers;

use Exporter 'import';
our @EXPORT_OK = qw( offer_terms instalment_plan );

# offer_terms($resource_id, %overrides): terms OfferVersion->draft accepts
# and publish allows: one one-time plan and an explicit refund policy.
sub offer_terms ( $resource_id, %overrides ) {
    return {
        resource_id          => $resource_id,
        price_cents          => 2000,
        units_per_acceptance => 1,
        per_booking_cap      => 1,
        payment_plans        => [ { id => 'pay', kind => 'one_time' } ],
        policies             => { refund => { kind => 'none' } },
        %overrides,
    };
}

# instalment_plan(%overrides): a payment plan of three monthly instalments.
sub instalment_plan (%overrides) {
    return { id => 'parts', kind => 'instalments', count => 3, cadence => 'monthly', %overrides };
}

1;
