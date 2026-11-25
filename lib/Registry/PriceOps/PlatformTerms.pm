# ABOUTME: The one place that answers which platform terms a tenant holds: its in-effect platform entitlement's version, plan, rate and refund policy.
# ABOUTME: No Free fallback: a tenant with no platform entitlement in effect is refused, naming the tenant.
use 5.42.0;
use experimental 'signatures';

package Registry::PriceOps::PlatformTerms;

use Exporter 'import';
our @EXPORT_OK = qw(platform_terms_for_tenant
                    platform_entitlement_terms platform_version_terms rate_fraction
                    platform_offers_to_tenants $SOLO_OFFER_ID);

use Mojo::JSON qw( from_json );
use Registry::DAO::Entitlement;

# The resource a tenant's platform entitlement buys; named, never a plan name.
my $PAYMENT_PROCESSING = 'payment processing';

# Solo, the offer signup preselects: the bootstrap seed's fixed offer id
# (bootstrap-platform-offers), never its name or its place in the listing.
our $SOLO_OFFER_ID = '00000000-0000-0000-0002-000000000001';

# What every terms lookup returns about an offer version and one of its plans.
my $TERMS_COLUMNS = q{
    v.id, p.id AS plan_id, o.name, v.price_cents, p.fraction,
    v.policies->'refund' AS refund_policy
};

# platform_terms_for_tenant($db, $tenant_slug) -> terms
#
# The tenant's platform terms now: platform_entitlement_terms at now(). The
# single source for the charge-time rate and every reader that shows it.
sub platform_terms_for_tenant ( $db, $tenant_slug ) {
    return platform_entitlement_terms( $db, $tenant_slug );
}

# platform_entitlement_terms($db, $tenant_slug, $at = now)
#   -> { id, plan_id, name, amount_cents, fraction, refund_policy }
#
# The terms of the tenant's platform entitlement to payment processing in
# effect at $at: the stamped offer version's id and accepted payment plan's
# id, the offer's name, the version's price, the plan's fraction and the
# version's refund policy. Read from registry only: a tenant schema's cloned
# entitlements cannot name a real tenant. Dies naming the tenant when none is
# in effect -- absence is not zero, and there is no fallback to Free or to 0.
sub platform_entitlement_terms ( $db, $tenant_slug, $at = undef ) {
    $db = $db->db if $db isa Registry::DAO;
    my $in_effect = Registry::DAO::Entitlement->in_effect_sql( 'e',
        q{tstzrange(coalesce(?::timestamptz, now()), coalesce(?::timestamptz, now()), '[]')} );

    # At most one row: the database refuses overlapping active platform
    # entitlements to payment processing (platform-entitlement-one-in-effect).
    my $row = $db->query( qq{
        SELECT $TERMS_COLUMNS
          FROM registry.entitlements e
          JOIN registry.tenants t ON t.id = e.holder_tenant_id
          JOIN registry.offer_versions v ON v.id = e.offer_version_id
          JOIN registry.offers o ON o.id = v.offer_id
          JOIN registry.resources r ON r.id = v.resource_id
          JOIN registry.offer_version_payment_plans p
            ON p.offer_version_id = v.id AND p.id = e.payment_plan_id
         WHERE t.slug = ? AND r.name = ? AND $in_effect
    }, $tenant_slug, $PAYMENT_PROCESSING, $at, $at )->hash;

    die "Tenant '$tenant_slug' holds no platform entitlement to $PAYMENT_PROCESSING in effect"
      . ( defined $at ? " at $at" : '' ) . " - there is no fallback to Free or to 0.\n"
        unless $row;

    return _entitlement_terms( $row, "the platform entitlement of tenant '$tenant_slug'" );
}

# platform_version_terms($db, $offer_version_id, $payment_plan_id)
#   -> { id, plan_id, name, amount_cents, fraction, refund_policy }
#
# The terms of a payment-processing offer version and one of its payment
# plans, superseded or not: a payment stamps both, and its refund resolves
# backwards from them.
sub platform_version_terms ( $db, $offer_version_id, $payment_plan_id ) {
    $db = $db->db if $db isa Registry::DAO;

    my $row = $db->query( qq{
        SELECT $TERMS_COLUMNS
          FROM registry.offer_versions v
          JOIN registry.offers o ON o.id = v.offer_id
          JOIN registry.resources r ON r.id = v.resource_id
          JOIN registry.offer_version_payment_plans p ON p.offer_version_id = v.id
         WHERE v.id = ? AND p.id = ? AND r.name = ?
    }, $offer_version_id, $payment_plan_id, $PAYMENT_PROCESSING )->hash;

    die "Offer version '$offer_version_id' with payment plan '$payment_plan_id' is not "
      . "a $PAYMENT_PROCESSING version and plan.\n"
        unless $row;

    return _entitlement_terms( $row, "offer version '$offer_version_id'" );
}

# platform_offers_to_tenants($db)
#   -> [ { id, offer_id, plan_id, name, amount_cents, currency, fraction, refund_policy } ]
#
# The platform's current published offers to tenants, cheapest first: each
# registry payment-processing version with a percentage-of-sales plan and
# without the holder_is_offerer condition, which marks the platform's offers
# to itself. Registry only: a studio's own offers live in its own schema.
# Only versions with no price: signup takes no card, so it cannot be paid for
# one with a monthly base, and does not offer what it cannot accept.
sub platform_offers_to_tenants ($db) {
    $db = $db->db if $db isa Registry::DAO;

    return $db->query( qq{
        SELECT $TERMS_COLUMNS, v.currency, v.offer_id
          FROM registry.offer_versions v
          JOIN registry.offers o ON o.id = v.offer_id
          JOIN registry.resources r ON r.id = v.resource_id
          JOIN registry.offer_version_payment_plans p
            ON p.offer_version_id = v.id AND p.kind = 'percentage_of_sales'
         WHERE r.name = ?
           AND v.published_at IS NOT NULL AND v.superseded_at IS NULL
           AND v.price_cents = 0
           AND NOT v.conditions \@> '[{"kind": "holder_is_offerer"}]'
         ORDER BY p.fraction, o.name
    }, $PAYMENT_PROCESSING )->hashes->map( sub ($row) {
        +{ %{ _entitlement_terms( $row, "offer version '$row->{id}'" ) }, currency => $row->{currency},
            offer_id => $row->{offer_id} };
    } )->to_array;
}

sub _entitlement_terms ( $row, $context ) {
    return {
        id            => $row->{id},
        plan_id       => $row->{plan_id},
        name          => $row->{name},
        amount_cents  => $row->{price_cents},
        fraction      => rate_fraction( $row->{fraction}, $context ),
        refund_policy => from_json( $row->{refund_policy} // 'null' )
            // die "No refund policy on $context.\n",
    };
}

# rate_fraction($raw, $context) -> decimal string
#
# The one rate rule: a fraction from 0 to 1 in whole basis points. Dies naming
# $context on anything else. Returned as an exact decimal string ("0.025"),
# never a float, so a snapshot of it is the rate itself.
sub rate_fraction ($raw, $context) {
    die "Revenue-share percentage is undefined for $context - the plan carries no "
      . "rate, so it has no revenue share to charge."
        unless defined $raw;

    # An exponent of nine digits at most keeps every count below an integer.
    die "Revenue-share percentage '$raw' is not numeric for $context - check pricing_configuration."
        unless $raw =~ /\A([-+]?)(?=\.?\d)(\d*)\.?(\d*)(?:[eE]([-+]?\d{1,9}))?\z/a;

    # Decimal digits and integer counts, never a float: the rate is 0.$digits
    # x 10^$point, with $digits stripped to its significant ones.
    my ( $negative, $digits, $point ) = ( $1 eq '-', $2 . $3, length($2) + ( $4 // 0 ) );
    $point -= length $1 if $digits =~ s/\A(0*)//;
    $digits =~ s/0+\z//;
    my $significant = length $digits;
    return '0' unless $significant;

    # The rate is a fraction, not a percent: 0.02 is 2%. A value outside [0,1]
    # is a unit mix-up (a bare "2" meaning 2%, or a dollar amount), and Stripe
    # rejects the resulting application_fee_amount at capture time. Refuse here,
    # where the message names the plan, rather than at the charge.
    die "Revenue-share percentage '$raw' is not a fraction between 0 and 1 for $context "
      . "- express the rate as a fraction (0.02 means 2%)."
        if ( $negative || $point > 1 || $point == 1 && $digits ne '1' );

    # Whole basis points, as the database and PricingPlan hold it: a finer rate
    # dies in application_fee_cents mid-checkout, so refuse it here by name.
    die "Revenue-share percentage '$raw' has more than 4 decimal places for $context "
      . "- a rate is whole basis points (0.0125 means 1.25%)."
        if $significant > $point + 4;

    return '1' if $point == 1;
    return '0.' . '0' x -$point . $digits;
}

1;
