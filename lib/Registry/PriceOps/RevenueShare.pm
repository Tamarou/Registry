# ABOUTME: Resolves the platform revenue-share fraction for a given tenant.
# ABOUTME: Reads the tenant's platform terms from PlatformTerms and returns the rate as a fraction (e.g. 0.02 for 2%).
use 5.42.0;
use experimental 'signatures';

package Registry::PriceOps::RevenueShare;

use Exporter 'import';
our @EXPORT_OK = qw(revenue_share_fraction_for_tenant platform_default_fraction platform_launch_fraction platform_launch_plan_id);

use Registry::DAO;
use Registry::PriceOps::PlatformTerms qw(platform_terms_for_tenant platform_default_terms rate_fraction);

# revenue_share_fraction_for_tenant($db, $tenant_slug) -> decimal string
#
# Returns the revenue-share fraction (e.g. "0.025" for 2.5%) of the named
# tenant's in-effect platform entitlement. All table references are fully
# qualified (registry.*) so this works regardless of the calling connection's
# search_path. Dies naming the tenant when it holds none: absence is not zero.
sub revenue_share_fraction_for_tenant ($db, $tenant_slug) {
    return platform_terms_for_tenant( $db, $tenant_slug )->{fraction};
}

# platform_default_fraction($db) -> number
#
# The platform's default ("Free") pricing plan's rate. No charge reads it: it
# is the single source the signup display reads when no launch plan resolves,
# until the Free-plan removal takes it away. Dies (deployment bug) if the
# seeded platform default plan is missing, never a silent 0%.
sub platform_default_fraction ($db) {
    return platform_default_terms($db)->{fraction};
}

# platform_launch_fraction($db) -> number
#
# The rate the platform SELLS -- what the signup copy quotes and what a tenant
# who takes the offered plan will be charged. Three functions here answer three
# different questions and are not interchangeable:
#
#   revenue_share_fraction_for_tenant  what THIS tenant is charged
#   platform_launch_fraction           what the platform advertises
#   platform_default_fraction          the Free plan's 0%, for the signup display
#
# Reading the launch rate off platform_default_fraction returns the Free plan's
# zero, and that is exactly how the copy once came to promise 2.5% while the
# platform charged 0% and 2% -- three rates live at once.
#
# Found by an explicit mark rather than by shape or ordering. "The newest
# tenant-scope percentage plan" is a coincidence that stops being true the
# moment a second one is seeded, and a resolver that picks between candidates
# is the ambiguity this exists to remove. Dies rather than guess.
sub platform_launch_fraction ($db) {
    return rate_fraction( _launch_plan_row($db)->{pct}, 'platform launch plan' );
}

# platform_launch_plan_id($db) -> uuid
#
# The id of that same plan, which the signup page displays. What a tenant is
# charged comes from the platform entitlement signup grants, not from this.
sub platform_launch_plan_id ($db) {
    return _launch_plan_row($db)->{id};
}

# _launch_plan_row($db) -> hashref { id, pct, plan_name }
#
# Current versions only, and for a sharper reason than the default above: this
# dies when more than one plan claims the mark. A revised launch plan leaves the
# retired version still carrying launch_rate, so without the filter the FIRST
# revise of the launch plan would take down the signup page that quotes the rate.
sub _launch_plan_row ($db) {
    $db = $db->db if $db isa Registry::DAO;

    my $rows = $db->query(q{
        SELECT id, pricing_configuration->>'percentage' AS pct, plan_name
          FROM registry.pricing_plans
         WHERE metadata->>'launch_rate' = 'true'
           AND superseded_at IS NULL
    })->hashes;

    die "No launch plan found in registry.pricing_plans "
      . "(metadata->>'launch_rate' = 'true'). This is a deployment bug - run "
      . "the set-launch-revenue-share-rate migration."
        unless $rows->size;

    die "Multiple plans are marked as the launch plan ("
      . join( ', ', map { $_->{plan_name} // '<unnamed>' } @$rows )
      . "). Exactly one plan carries the rate the platform advertises."
        if $rows->size > 1;

    return $rows->first;
}

1;
