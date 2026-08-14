# ABOUTME: Resolves the platform revenue-share fraction for a given tenant.
# ABOUTME: Looks up the tenant's linked pricing plan and returns the configured percentage as a fraction (e.g. 0.02 for 2%).
use 5.42.0;
use experimental 'signatures';

package Registry::PriceOps::RevenueShare;

use Exporter 'import';
our @EXPORT_OK = qw(revenue_share_fraction_for_tenant platform_default_fraction refund_application_fee_for_tenant);

use Registry::DAO;

# revenue_share_fraction_for_tenant($db, $tenant_slug) -> number
#
# Returns the revenue-share fraction (e.g. 0.02 for 2%) for the named tenant.
# All table references are fully qualified (registry.*) so this works correctly
# regardless of the calling connection's search_path.
#
# Resolution order:
#   1. tenant.platform_pricing_plan_id is set  -> use that plan's percentage
#   2. FK is NULL or tenant row absent          -> use the platform Free plan (0.00)
#   3. Free plan missing                        -> die (deployment bug)
#   4. Resolved percentage absent or non-numeric -> die (data bug)
sub revenue_share_fraction_for_tenant ($db, $tenant_slug) {
    $db = $db->db if $db isa Registry::DAO;

    # Step 1: look up the tenant's explicitly linked plan rate.
    # pricing_configuration->>'percentage' is the only source. The money column
    # holds money, never a rate -- a plan with no rate declared resolves to NULL
    # and dies in _coerce_pct rather than having one inferred from its price.
    my $row = $db->query(q{
        SELECT p.pricing_configuration->>'percentage' AS pct
          FROM registry.tenants t
          JOIN registry.pricing_plans p
            ON p.id = t.platform_pricing_plan_id
         WHERE t.slug = ?
    }, $tenant_slug)->hash;

    if ($row) {
        return _coerce_pct($row->{pct}, "linked plan for tenant '$tenant_slug'");
    }

    # Step 2: tenant has no linked plan (NULL FK, or tenant row absent).
    # Fall back to the seeded platform default (Free) plan.
    return platform_default_fraction($db);
}

# platform_default_fraction($db) -> number
#
# The platform's default ("Free") revenue-share fraction -- the fallback when a
# tenant has no linked plan, and the single source the signup display reads so
# the displayed and charged rates cannot diverge. Dies (deployment bug) if the
# seeded platform default plan is missing -- the same fail-loud behavior as the
# charge path, never a silent 0%.
sub platform_default_fraction ($db) {
    $db = $db->db if $db isa Registry::DAO;

    my $free_row = $db->query(q{
        SELECT pricing_configuration->>'percentage' AS pct
          FROM registry.pricing_plans
         WHERE plan_scope = 'platform'
           AND metadata->>'default' = 'true'
         LIMIT 1
    })->hash;

    die "No platform default (Free) plan found in registry.pricing_plans "
      . "(plan_scope='platform', metadata->>'default'='true'). "
      . "This is a deployment bug - run the seed-free-platform-plan migration."
        unless $free_row;

    return _coerce_pct($free_row->{pct}, "platform default (Free) plan");
}

# refund_application_fee_for_tenant($db, $tenant_slug) -> 1 or 0
#
# Returns whether the platform refunds its application fee when a tenant payment
# is refunded. Reads the boolean field refund_application_fee from the tenant's
# linked pricing plan's pricing_configuration. Postgres ->> returns 'true'/'false'
# as strings; this sub returns 1/0.
#
# Resolution order:
#   1. tenant.platform_pricing_plan_id is set  -> use that plan's setting
#   2. FK is NULL or tenant row absent          -> use the platform default plan's setting
#   3. Either plan has the key absent/null      -> default true (1)
#   4. Platform default plan missing            -> die (deployment bug)
#   5. Value present but not 'true'/'false'     -> die (data bug)
sub refund_application_fee_for_tenant ($db, $tenant_slug) {
    $db = $db->db if $db isa Registry::DAO;

    # Step 1: look up the tenant's explicitly linked plan refund flag.
    my $row = $db->query(q{
        SELECT p.pricing_configuration->>'refund_application_fee' AS raw
          FROM registry.tenants t
          JOIN registry.pricing_plans p
            ON p.id = t.platform_pricing_plan_id
         WHERE t.slug = ?
    }, $tenant_slug)->hash;

    if ($row) {
        return _coerce_refund_flag($row->{raw});
    }

    # Step 2: tenant has no linked plan (NULL FK, or tenant row absent).
    # Fall back to the seeded platform default plan's setting.
    return _platform_default_refund_flag($db);
}

# _platform_default_refund_flag($db) -> 1 or 0
#
# Reads refund_application_fee from the platform default plan. Key absent/null
# means default true (1). Missing plan entirely is a deployment bug -- die loudly
# to mirror the behavior of platform_default_fraction.
sub _platform_default_refund_flag ($db) {
    my $r = $db->query(q{
        SELECT pricing_configuration->>'refund_application_fee' AS raw
          FROM registry.pricing_plans
         WHERE plan_scope = 'platform'
           AND metadata->>'default' = 'true'
         LIMIT 1
    })->hash;

    die "No platform default (Free) plan found in registry.pricing_plans "
      . "(plan_scope='platform', metadata->>'default'='true'). "
      . "This is a deployment bug - run the seed-free-platform-plan migration."
        unless $r;

    return _coerce_refund_flag($r->{raw});
}

# _coerce_refund_flag($raw) -> 1 or 0
# Coerces a Postgres ->> boolean string to 1 or 0. Key absent (undef) defaults to 1.
# Dies on any value that is not 'true', 'false', or undef.
sub _coerce_refund_flag ($raw) {
    return 1 unless defined $raw;       # key absent/null -> default true
    return 1 if $raw eq 'true';
    return 0 if $raw eq 'false';
    die "refund_application_fee must be 'true' or 'false', got '$raw' "
      . "- check pricing_configuration in registry.pricing_plans.";
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

    return $raw + 0;
}

1;
