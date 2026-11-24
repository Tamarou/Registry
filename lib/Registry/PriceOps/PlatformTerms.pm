# ABOUTME: The one place that answers which platform terms a tenant holds: id, name, rate fraction and monthly amount.
# ABOUTME: Column-backed today (tenants.platform_pricing_plan_id, Free fallback); the switch to entitlements changes only this file.
use 5.42.0;
use experimental 'signatures';

package Registry::PriceOps::PlatformTerms;

use Exporter 'import';
our @EXPORT_OK = qw(platform_terms_for_tenant platform_default_terms);

# platform_terms_for_tenant($db, $tenant_slug) -> { id, name, fraction, amount_cents }
#
# id is the identifier of the terms (today the plan id; after the switch, the
# offer version id). Every table is qualified with registry, so the answer is
# the same on a tenant-schema connection as on the registry one.
#
# Resolution order:
#   1. tenant.platform_pricing_plan_id is set  -> that plan
#   2. FK is NULL or tenant row absent          -> the platform Free plan
#   3. Free plan missing                        -> die (deployment bug)
#   4. Resolved percentage absent or malformed  -> die (data bug)
#
# No refund flag: refunds keep the platform fee for every seller (ADR 003,
# ruling 8a); the spec moves that rule onto the Solo offer's refund policy.
sub platform_terms_for_tenant ($db, $tenant_slug) {
    $db = $db->db if $db isa Registry::DAO;

    # Deliberately NOT filtered on superseded_at. This is a lookup BY ID: the
    # tenant's link points at a specific plan VERSION, and it keeps pointing there
    # after that version is retired. Revising a plan must not silently re-price
    # the tenants already on it (#277).
    my $row = $db->query(q{
        SELECT p.id, p.plan_name, p.amount_cents,
               p.pricing_configuration->>'percentage' AS pct
          FROM registry.tenants t
          JOIN registry.pricing_plans p
            ON p.id = t.platform_pricing_plan_id
         WHERE t.slug = ?
    }, $tenant_slug)->hash;

    return _terms( $row, "linked plan for tenant '$tenant_slug'" ) if $row;

    return platform_default_terms($db);
}

# platform_default_terms($db) -> { id, name, fraction, amount_cents }
#
# The platform's default ("Free") plan -- the fallback when a tenant has no
# linked plan. Current versions only: this is a SEARCH by mark, and a retired
# version still carries the mark.
sub platform_default_terms ($db) {
    $db = $db->db if $db isa Registry::DAO;

    my $row = $db->query(q{
        SELECT id, plan_name, amount_cents,
               pricing_configuration->>'percentage' AS pct
          FROM registry.pricing_plans
         WHERE plan_scope = 'platform'
           AND metadata->>'default' = 'true'
           AND superseded_at IS NULL
         LIMIT 1
    })->hash;

    die "No platform default (Free) plan found in registry.pricing_plans "
      . "(plan_scope='platform', metadata->>'default'='true'). "
      . "This is a deployment bug - run the seed-free-platform-plan migration."
        unless $row;

    return _terms( $row, "platform default (Free) plan" );
}

sub _terms ($row, $context) {
    return {
        id           => $row->{id},
        name         => $row->{plan_name},
        fraction     => _coerce_pct( $row->{pct}, $context ),
        amount_cents => $row->{amount_cents},
    };
}

# _coerce_pct($raw, $context) -> number
# Validates and coerces a raw percentage string to a number. Dies on malformed input.
sub _coerce_pct ($raw, $context) {
    die "Revenue-share percentage is undefined for $context - the plan carries no "
      . "'percentage' in pricing_configuration, so it has no revenue-share rate."
        unless defined $raw;

    die "Revenue-share percentage '$raw' is not numeric for $context - check pricing_configuration."
        unless $raw =~ /\A[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\z/;

    # The rate is a fraction, not a percent: 0.02 is 2%. A value outside [0,1]
    # is a unit mix-up (a bare "2" meaning 2%, or a dollar amount), and Stripe
    # rejects the resulting application_fee_amount at capture time. Refuse here,
    # where the message names the plan, rather than at the charge.
    die "Revenue-share percentage '$raw' is not a fraction between 0 and 1 for $context "
      . "- express the rate as a fraction (0.02 means 2%)."
        unless $raw >= 0 && $raw <= 1;

    # Whole basis points, as the database and PricingPlan hold it: a finer rate
    # dies in application_fee_cents mid-checkout, so refuse it here by name.
    die "Revenue-share percentage '$raw' has more than 4 decimal places for $context "
      . "- a rate is whole basis points (0.0125 means 1.25%)."
        unless abs( $raw * 10_000 - sprintf '%.0f', $raw * 10_000 ) < 1e-6;

    return $raw + 0;
}

1;
