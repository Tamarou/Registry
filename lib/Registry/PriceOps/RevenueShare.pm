# ABOUTME: Resolves the platform revenue-share fraction for a given tenant.
# ABOUTME: Looks up the tenant's linked pricing plan and returns the configured percentage as a fraction (e.g. 0.02 for 2%).
use 5.42.0;
use experimental 'signatures';

package Registry::PriceOps::RevenueShare;

use Exporter 'import';
our @EXPORT_OK = qw(revenue_share_fraction_for_tenant);

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
#   4. Resolved percentage non-numeric          -> die (data bug)
sub revenue_share_fraction_for_tenant ($db, $tenant_slug) {
    $db = $db->db if $db isa Registry::DAO;

    # Step 1: look up the tenant's explicitly linked plan rate.
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
    # Fall back to the seeded platform Free plan.
    my $free_row = $db->query(q{
        SELECT pricing_configuration->>'percentage' AS pct
          FROM registry.pricing_plans
         WHERE plan_scope = 'platform'
           AND metadata->>'default' = 'true'
         LIMIT 1
    })->hash;

    die "No platform Free fallback plan found in registry.pricing_plans "
      . "(plan_scope='platform', metadata->>'default'='true'). "
      . "This is a deployment bug - run the create-default-pricing-relationships migration."
        unless $free_row;

    return _coerce_pct($free_row->{pct}, "platform Free fallback plan");
}

# _coerce_pct($raw, $context) -> number
# Validates and coerces a raw percentage string to a number. Dies on malformed input.
sub _coerce_pct ($raw, $context) {
    die "Revenue-share percentage is undefined for $context - check pricing_configuration."
        unless defined $raw;

    die "Revenue-share percentage '$raw' is not numeric for $context - check pricing_configuration."
        unless $raw =~ /\A[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\z/;

    return $raw + 0;
}

1;
