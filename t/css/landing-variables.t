# ABOUTME: Tests that all --landing-* CSS variables are defined in theme.css.
# ABOUTME: These aliases are required by app.css landing page component styles.
use 5.34.0;
use Test::More;
use Mojo::File qw(curfile);

my $root = curfile->dirname->dirname->dirname;
my $theme_css = $root->child('public/css/theme.css')->slurp;

my @required_vars = qw(
    --landing-bg-primary
    --landing-bg-secondary
    --landing-text-primary
    --landing-text-secondary
    --landing-accent-pink
    --landing-accent-cyan
    --landing-accent-purple
    --landing-accent-blue
    --landing-gradient-1
    --landing-gradient-2
    --landing-card-bg
    --landing-glow-color
    --landing-grid-color
);

for my $var (@required_vars) {
    my @matches = ($theme_css =~ /\Q$var\E\s*:/g);
    cmp_ok(scalar @matches, '>=', 2, "$var defined in both light and dark mode");
}

done_testing;
