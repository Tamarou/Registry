# ABOUTME: Tests that the tenant-signup profile template uses correct CSS selectors.
# ABOUTME: Validates subdomain-slug uses ID selector (#) not class selector (.).
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

done_testing;
