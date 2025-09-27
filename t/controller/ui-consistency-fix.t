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
    my $css_file = 'public/css/style.css';

    ok(-f $landing_template, 'Landing page template exists');
    ok(-f $workflow_template, 'Workflow template exists');
    ok(-f $css_file, 'Central CSS file exists');

    # Read template contents
    my $landing_content;
    open my $landing_fh, '<', $landing_template or die "Cannot read landing template: $!";
    { local $/; $landing_content = <$landing_fh>; }
    close $landing_fh;

    my $workflow_content;
    open my $workflow_fh, '<', $workflow_template or die "Cannot read workflow template: $!";
    { local $/; $workflow_content = <$workflow_fh>; }
    close $workflow_fh;

    # Read CSS file content
    my $css_content;
    open my $css_fh, '<', $css_file or die "Cannot read CSS file: $!";
    { local $/; $css_content = <$css_fh>; }
    close $css_fh;

    # Check that templates do NOT have embedded CSS (confirming they use external files)
    my $landing_has_embedded_css = $landing_content =~ /<style[^>]*>/;
    my $workflow_has_embedded_css = $workflow_content =~ /<style[^>]*>/;

    ok(!$landing_has_embedded_css, 'Landing page does not have embedded CSS - uses external files');
    ok(!$workflow_has_embedded_css, 'Workflow does not have embedded CSS - uses external files');

    # Check that CSS variables are properly defined in the external CSS file
    my $css_has_color_vars = $css_content =~ /--color-primary/;
    ok($css_has_color_vars, 'CSS variables are defined in external CSS file');

    # Check that both templates reference the external CSS file
    my $landing_references_css = $landing_content =~ /CSS moved to registry\.css/;
    my $workflow_references_css = $workflow_content =~ /CSS moved to registry\.css/;

    ok($landing_references_css, 'Landing page indicates CSS was moved to external file');
    ok($workflow_references_css, 'Workflow indicates CSS was moved to external file');
};

subtest 'button style consistency' => sub {
    # Check that both pages use consistent button styling from the unified CSS system
    my $landing_template = 'templates/index.html.ep';
    my $workflow_template = 'templates/tenant-signup/index.html.ep';
    my $css_file = 'public/css/style.css';

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

    # Check that workflow template uses consistent button classes
    my $workflow_has_btn_primary = $workflow_content =~ /btn-primary/;
    ok($workflow_has_btn_primary, 'Workflow has btn-primary class');

    # Check that landing page uses semantic data attributes (modern approach)
    my $landing_has_semantic_buttons = $landing_content =~ /data-variant="success"/;
    ok($landing_has_semantic_buttons, 'Landing page uses semantic button data attributes');

    # Check that buttons are defined in the central CSS system
    my $css_has_buttons = $css_content =~ /\.btn\s*\{/;
    ok($css_has_buttons, 'Button styles are centrally defined in style.css');

    # Workflow should not redefine button styles
    my $workflow_defines_buttons = $workflow_content =~ /\.btn\s*\{/;
    ok(!$workflow_defines_buttons, 'Workflow does not redefine button styles - uses unified system');
};

subtest 'color scheme consistency' => sub {
    # Check for consistent vaporwave color scheme in CSS and layout
    my $workflow_layout = 'templates/layouts/workflow.html.ep';
    my $css_file = 'public/css/style.css';

    my $workflow_content;
    open my $workflow_fh, '<', $workflow_layout or die "Cannot read workflow layout: $!";
    { local $/; $workflow_content = <$workflow_fh>; }
    close $workflow_fh;

    my $css_content;
    open my $css_fh, '<', $css_file or die "Cannot read CSS file: $!";
    { local $/; $css_content = <$css_fh>; }
    close $css_fh;

    # Check that colors are accessible via style.css (through import from structure.css)
    my $structure_css_file = 'public/css/structure.css';
    my $structure_css_content;
    open my $structure_fh, '<', $structure_css_file or die "Cannot read structure CSS file: $!";
    { local $/; $structure_css_content = <$structure_fh>; }
    close $structure_fh;

    # Check for CSS color variables in structure.css (design tokens)
    my $css_has_color_vars = $structure_css_content =~ /--color-primary:\s*#BF349A/ &&
                           $structure_css_content =~ /--color-primary-dark:\s*#8C2771/ &&
                           $structure_css_content =~ /--color-secondary:\s*#2ABFBF/;
    ok($css_has_color_vars, 'CSS defines vaporwave colors as CSS variables');

    # Check that style.css imports structure.css
    my $css_imports_structure = $css_content =~ /\@import.*structure\.css/;
    ok($css_imports_structure, 'Style.css imports structure.css for color access');

    # Verify vaporwave colors are used in CSS
    my $css_uses_vaporwave = $structure_css_content =~ /#BF349A/ && $structure_css_content =~ /#8C2771/ && $structure_css_content =~ /#2ABFBF/;
    ok($css_uses_vaporwave, 'CSS architecture provides vaporwave color palette');
};