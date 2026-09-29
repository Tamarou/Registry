# ABOUTME: Tests the tenant-signup profile template's subdomain preview markup.
# ABOUTME: Validates subdomain branding says "tinyartempire.com" not "registry.com".
use 5.34.0;
use Test::More;
use Mojo::File qw(curfile);

my $root = curfile->dirname->dirname->dirname;
my $content = $root->child('templates/tenant-signup/profile.html.ep')->slurp;

# The preview is filled by /tenant-signup/validate-subdomain over HTMX, which
# derives the slug with the same function that provisions it. A second
# derivation in JavaScript used to live in this file and disagreed with the
# first -- it joined with hyphens where provisioning used underscores -- so the
# applicant was shown a URL their studio would never answer at.
unlike($content, qr/querySelector\(['"][.#]subdomain-slug['"]\)/,
    'profile.html.ep derives no slug of its own');
like($content, qr/hx-post="\/tenant-signup\/validate-subdomain"/,
    'the preview comes from the endpoint instead');

# Branding: subdomain preview must reference tinyartempire.com, not registry.com
like($content, qr/tinyartempire\.com/,
    'profile.html.ep contains tinyartempire.com');
unlike($content, qr/\.registry\.com/,
    'profile.html.ep does not reference registry.com');

# The element the endpoint targets must exist in the HTML
like($content, qr/id="subdomain-preview"/,
    'profile.html.ep has element with id="subdomain-preview"');

done_testing;
