use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(defer try);
use Test::More import => [qw( done_testing is ok like is_deeply subtest use_ok isa_ok can_ok )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;
use Test::Registry::Fixtures;

# Test UI consistency between landing page and tenant signup workflow

# Set up test data
my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;

subtest 'template layout consistency' => sub {
    # Read templates to check for consistency
    my $landing_template = 'templates/index.html.ep';
    my $workflow_template = 'templates/tenant-signup/index.html.ep';

    ok(-f $landing_template, 'Landing page template exists');
    ok(-f $workflow_template, 'Workflow template exists');

    # Read landing page content
    my $landing_content;
    open my $landing_fh, '<', $landing_template or die "Cannot read landing template: $!";
    { local $/; $landing_content = <$landing_fh>; }
    close $landing_fh;

    # Read workflow content
    my $workflow_content;
    open my $workflow_fh, '<', $workflow_template or die "Cannot read workflow template: $!";
    { local $/; $workflow_content = <$workflow_fh>; }
    close $workflow_fh;

    # Check that both use consistent CSS variables for colors
    my $landing_uses_vars = $landing_content =~ /var\(--color-/;
    my $workflow_uses_vars = $workflow_content =~ /var\(--color-/;

    ok($landing_uses_vars, 'Landing page uses CSS variables');

    # After our fix, workflow should also use CSS variables
    if (!$workflow_uses_vars) {
        ok(0, 'EXPECTED FAILURE: Workflow templates need CSS variable consistency');
    } else {
        ok(1, 'Workflow uses consistent CSS variables');
    }
};

subtest 'button style consistency' => sub {
    # Check that both pages use consistent button styling from the unified CSS system
    my $landing_template = 'templates/index.html.ep';
    my $workflow_template = 'templates/tenant-signup/index.html.ep';
    my $css_file = 'public/css/registry.css';

    my $landing_content;
    open my $landing_fh, '<', $landing_template or die "Cannot read landing template: $!";
    { local $/; $landing_content = <$landing_fh>; }
    close $landing_fh;

    my $workflow_content;
    open my $workflow_fh, '<', $workflow_template or die "Cannot read workflow template: $!";
    { local $/; $workflow_content = <$workflow_fh>; }
    close $workflow_fh;

    my $css_content;
    open my $css_fh, '<', $css_file or die "Cannot read CSS file: $!";
    { local $/; $css_content = <$css_fh>; }
    close $css_fh;

    # Check that both templates use consistent button classes
    my $landing_has_btn_success = $landing_content =~ /btn-success/;
    my $workflow_has_btn_primary = $workflow_content =~ /btn-primary/;

    ok($landing_has_btn_success, 'Landing page has btn-success class');
    ok($workflow_has_btn_primary, 'Workflow has btn-primary class');

    # Check that buttons are defined in the central CSS system
    my $css_has_buttons = $css_content =~ /\.btn\s*\{/;
    ok($css_has_buttons, 'Button styles are centrally defined in registry.css');

    # Workflow should not redefine button styles
    my $workflow_defines_buttons = $workflow_content =~ /\.btn\s*\{/;
    ok(!$workflow_defines_buttons, 'Workflow does not redefine button styles - uses unified system');
};

subtest 'color scheme consistency' => sub {
    # Check for consistent gradient usage
    my $landing_template = 'templates/index.html.ep';
    my $workflow_layout = 'templates/layouts/workflow.html.ep';

    my $landing_content;
    open my $landing_fh, '<', $landing_template or die "Cannot read landing template: $!";
    { local $/; $landing_content = <$landing_fh>; }
    close $landing_fh;

    my $workflow_content;
    open my $workflow_fh, '<', $workflow_layout or die "Cannot read workflow layout: $!";
    { local $/; $workflow_content = <$workflow_fh>; }
    close $workflow_fh;

    # Both should use the same gradient
    my $landing_gradient = $landing_content =~ /#667eea.*#764ba2/;
    my $workflow_gradient = $workflow_content =~ /#667eea.*#764ba2/;

    ok($landing_gradient, 'Landing page has purple gradient');
    ok($workflow_gradient, 'Workflow layout has purple gradient');
};