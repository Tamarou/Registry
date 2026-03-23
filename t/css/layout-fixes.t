# ABOUTME: Tests for CSS layout fixes - validates nav z-index, workflow max-width, and feature card grid.
# ABOUTME: Checks fixes for GitHub issues #127 (sticky nav overlap), #130 (narrow workflow), #132 (card orphan).
use 5.34.0;
use Test::More;
use Mojo::File qw(curfile);

my $root    = curfile->dirname->dirname->dirname;
my $app_css = $root->child('public/css/app.css')->slurp;

# ---------------------------------------------------------------------------
# Issue #127: Sticky navbar z-index must be high enough to avoid overlap
# ---------------------------------------------------------------------------
subtest 'nav z-index is sufficient to prevent content overlap (issue #127)' => sub {
    # Landing nav z-index
    my ($landing_nav_block) = ($app_css =~ /\.landing-nav\s*\{([^}]+)\}/s);
    ok($landing_nav_block, 'landing-nav rule block is present');

    my ($landing_z) = ($landing_nav_block =~ /z-index\s*:\s*(\d+)/);
    ok(defined $landing_z, 'landing-nav has a z-index value');
    cmp_ok($landing_z, '>=', 1000, "landing-nav z-index ($landing_z) is >= 1000");

    # Workflow nav z-index
    my ($workflow_nav_block) = ($app_css =~ /nav\.workflow-nav\s*\{([^}]+)\}/s);
    ok($workflow_nav_block, 'workflow-nav rule block is present');

    my ($workflow_z) = ($workflow_nav_block =~ /z-index\s*:\s*(\d+)/);
    ok(defined $workflow_z, 'workflow-nav has a z-index value');
    cmp_ok($workflow_z, '>=', 1000, "workflow-nav z-index ($workflow_z) is >= 1000");

    # Both navs must be position: fixed
    like($landing_nav_block,  qr/position\s*:\s*fixed/, 'landing-nav uses position: fixed');
    like($workflow_nav_block, qr/position\s*:\s*fixed/, 'workflow-nav uses position: fixed');
};

subtest 'workflow container has enough top clearance for sticky nav on mobile (issue #127)' => sub {
    # The mobile media query for main[data-component="workflow-container"] must set margin-top
    # to at least 5rem so content is not hidden behind the fixed nav bar.
    my ($mobile_block) = ($app_css =~ /\@media[^{]*max-width[^{]*768px[^{]*\{(.+)/s);
    ok($mobile_block, 'mobile media query block is present');

    my ($container_block) = ($mobile_block =~ /main\[data-component="workflow-container"\]\s*\{([^}]+)\}/s);
    ok($container_block, 'workflow-container rule exists in mobile media query');

    my ($margin_top) = ($container_block =~ /margin-top\s*:\s*([\d.]+)rem/);
    ok(defined $margin_top, 'workflow-container has margin-top in mobile block');
    cmp_ok($margin_top + 0, '>=', 5, "mobile workflow-container margin-top (${margin_top}rem) is >= 5rem");
};

# ---------------------------------------------------------------------------
# Issue #130: Workflow container max-width should be >= 800px
# ---------------------------------------------------------------------------
subtest 'workflow container max-width is at least 800px (issue #130)' => sub {
    my ($container_block) = ($app_css =~ /main\[data-component="workflow-container"\]\s*\{([^}]+)\}/s);
    ok($container_block, 'workflow-container rule block is present');

    my ($max_width_val) = ($container_block =~ /max-width\s*:\s*(\d+)px/);
    ok(defined $max_width_val, 'workflow-container has a px max-width value');
    cmp_ok($max_width_val + 0, '>=', 800,
        "workflow-container max-width (${max_width_val}px) is >= 800px");
};

# ---------------------------------------------------------------------------
# Issue #132: Feature card grid must not produce a 3+1 orphan at desktop
# ---------------------------------------------------------------------------
subtest 'feature card grid uses explicit column count, not auto-fit with 300px minimum (issue #132)' => sub {
    my ($grid_block) = ($app_css =~ /\.landing-features-grid[^{]*\{([^}]+)\}/s);
    ok($grid_block, 'landing-features-grid rule block is present');

    my ($grid_template) = ($grid_block =~ /grid-template-columns\s*:\s*([^;]+)/);
    ok(defined $grid_template, 'landing-features-grid has grid-template-columns');

    # The problematic pattern was: repeat(auto-fit, minmax(300px, 1fr))
    # At ~1130px available width this yields 3 columns and orphans the 4th card.
    unlike($grid_template, qr/auto-fit.*minmax.*300px/,
        'grid does not use auto-fit with 300px minimum (which caused 3+1 orphan)');

    # Must be an explicit 2- or 4-column layout
    like($grid_template, qr/repeat\(\s*[24]\s*,/,
        'landing-features-grid uses an explicit 2 or 4 column repeat');
};

subtest 'wide-screen breakpoint provides 4-across feature card layout (issue #132)' => sub {
    # There must be a min-width media query that upgrades the grid to 4 columns
    my ($wide_block) = ($app_css =~ /\@media[^{]*min-width[^{]*1280px[^{]*\{([^}]+(?:\{[^}]*\}[^}]*)*)\}/s);
    ok($wide_block, 'wide-screen (min-width: 1280px) media query block is present');

    like($wide_block, qr/landing-features-grid|features-grid/,
        'wide-screen breakpoint targets the feature grid');
    like($wide_block, qr/repeat\(\s*4\s*,/,
        'wide-screen breakpoint sets 4-column feature grid');
};

subtest 'mobile breakpoint collapses feature grid to single column (issue #132)' => sub {
    my ($mobile_block) = ($app_css =~ /\@media[^{]*max-width[^{]*768px[^{]*\{(.+)/s);
    ok($mobile_block, 'mobile media query block is present');

    like($mobile_block, qr/landing-features-grid|features-grid/,
        'mobile breakpoint targets the feature grid');
    like($mobile_block, qr/grid-template-columns\s*:\s*1fr/,
        'mobile breakpoint collapses feature grid to 1 column');
};

done_testing;
