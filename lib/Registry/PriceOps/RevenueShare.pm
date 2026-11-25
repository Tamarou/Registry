# ABOUTME: Resolves the platform revenue-share fraction for a given tenant.
# ABOUTME: Reads the tenant's platform terms from PlatformTerms and returns the rate as a fraction (e.g. 0.02 for 2%).
use 5.42.0;
use experimental 'signatures';

package Registry::PriceOps::RevenueShare;

use Exporter 'import';
our @EXPORT_OK = qw(revenue_share_fraction_for_tenant platform_offered_fraction platform_offered_percent);

use Registry::PriceOps::PlatformTerms qw(platform_terms_for_tenant platform_offers_to_tenants);

# revenue_share_fraction_for_tenant($db, $tenant_slug) -> decimal string
#
# Returns the revenue-share fraction (e.g. "0.025" for 2.5%) of the named
# tenant's in-effect platform entitlement. All table references are fully
# qualified (registry.*) so this works regardless of the calling connection's
# search_path. Dies naming the tenant when it holds none: absence is not zero.
sub revenue_share_fraction_for_tenant ($db, $tenant_slug) {
    return platform_terms_for_tenant( $db, $tenant_slug )->{fraction};
}

# platform_offered_fraction($db) -> decimal string
#
# The rate the platform SELLS -- what the signup copy quotes: the rate of the
# platform's one current published offer to tenants, so publishing a later Solo
# version through offer-publishing moves the quote with no migration. Not
# interchangeable with revenue_share_fraction_for_tenant, which answers what
# THIS tenant is charged: a holder keeps its stamped version's rate. Dies
# rather than guess when there is not exactly one offer, and never defaults.
sub platform_offered_fraction ($db) {
    my $offers = platform_offers_to_tenants($db);
    die "The platform has no current published offer to tenants. Publish one "
      . "through offer-publishing.\n"
        unless @$offers;
    die "The platform has " . scalar(@$offers) . " current published offers to tenants ("
      . join( ', ', map { $_->{name} } @$offers )
      . ") and quotes exactly one rate. Retire all but one through offer-publishing.\n"
        if @$offers > 1;
    return $offers->[0]{fraction};
}

# platform_offered_percent($db) -> number or undef
#
# platform_offered_fraction as the copy shows it (2.5 for 0.025). Undef when it
# refuses, so a page quotes no rate rather than a default one.
sub platform_offered_percent ($db) {
    my $fraction = eval { platform_offered_fraction($db) } // return undef;
    return 0 + sprintf '%g', $fraction * 100;
}

1;
