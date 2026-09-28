# ABOUTME: Resolves the platform base domain that tenant subdomains are served under.
# ABOUTME: Single source for REGISTRY_BASE_DOMAINS parsing, so links agree with routing.
use 5.42.0;
use experimental 'signatures';

package Registry::Utility::BaseDomain;

use Exporter 'import';
our @EXPORT_OK = qw(base_domains primary_base_domain tenant_url);

# The platform base domains under which wildcard tenant subdomains are served,
# in the order they are configured. Registry.pm uses the whole list to decide
# whether an incoming host is a tenant subdomain; link builders want the first.
sub base_domains {
    my $raw = $ENV{REGISTRY_BASE_DOMAINS} // 'tinyartempire.com,localhost';
    return grep { length } map { s/^\s+|\s+$//gr } map { lc } split /,/, $raw;
}

sub primary_base_domain {
    my ($first) = base_domains();
    return $first // 'tinyartempire.com';
}

# https://<slug>.<base>, with an optional path appended. The completion page
# used to hardcode 'registry.localhost' here, so every link it handed a new
# tenant -- dashboard, login, passkey registration -- pointed at a hostname that
# does not resolve outside a developer's machine.
sub tenant_url ($slug, $path = '') {
    return sprintf 'https://%s.%s%s', $slug, primary_base_domain(), $path;
}

1;
