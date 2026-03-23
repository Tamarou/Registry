# ABOUTME: Tests that the tenant-signup profile template uses correct CSS selectors.
# ABOUTME: Validates subdomain branding says "tinyartempire.com" not "registry.com".
use 5.34.0;
use Test::More;
use Mojo::File qw(curfile);

my $root = curfile->dirname->dirname->dirname;
my $content = $root->child('templates/tenant-signup/profile.html.ep')->slurp;

# The subdomain preview element uses id="subdomain-slug", so JS must use # selector
unlike($content, qr/querySelector\(['"]\.subdomain-slug['"]\)/,
    'profile.html.ep does not use class selector for subdomain-slug');
like($content, qr/querySelector\(['"]#subdomain-slug['"]\)/,
    'profile.html.ep uses ID selector for subdomain-slug');

# Branding: subdomain preview must reference tinyartempire.com, not registry.com
like($content, qr/tinyartempire\.com/,
    'profile.html.ep contains tinyartempire.com');
unlike($content, qr/\.registry\.com/,
    'profile.html.ep does not reference registry.com');

# The element targeted by JS must exist in the HTML
like($content, qr/id="subdomain-slug"/,
    'profile.html.ep has element with id="subdomain-slug"');

done_testing;
