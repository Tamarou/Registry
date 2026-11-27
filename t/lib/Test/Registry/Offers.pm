# ABOUTME: Test helper giving a complete, valid set of day-one offer version terms.
# ABOUTME: Tests override only the terms they are about, so each states its subject and nothing else.
use 5.42.0;
use warnings;

package Test::Registry::Offers;

use Exporter 'import';
our @EXPORT_OK = qw( offer_terms instalment_plan published_as_migrated );

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

# published_as_migrated($db, $offer_name, %columns): the id of version 1 of a
# new offer, published with offer_terms' one-time plan and refund policy, by
# plain SQL. For tests that deploy only part of the sqitch plan, where
# OfferVersion, which follows the head schema, cannot be used. %columns names
# resource_id, class_project_id or resource_ids, and any price override.
sub published_as_migrated ( $db, $offer_name, %columns ) {
    my $terms   = offer_terms( undef, %columns );
    my $offer   = $db->insert( 'offers', { name => $offer_name }, { returning => 'id' } )->hash->{id};
    my $version = $db->insert( 'offer_versions', {
        offer_id => $offer, version => 1,
        $terms->%{qw( resource_id class_project_id price_cents units_per_acceptance per_booking_cap )},
        policies => { -json => $terms->{policies} },
    }, { returning => 'id' } )->hash->{id};
    $db->insert( 'offer_version_payment_plans', { offer_version_id => $version, $_->%* } )
        for $terms->{payment_plans}->@*;
    $db->insert( 'offer_version_resources', { offer_version_id => $version, resource_id => $_ } )
        for ( $terms->{resource_ids} // [] )->@*;
    $db->update( 'offer_versions', { published_at => \'now()' }, { id => $version } );
    return $version;
}

1;
