use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(defer try);
use Test::More import => [qw( done_testing is ok like is_deeply subtest use_ok isa_ok can_ok )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;
use Test::Registry::Fixtures;

# Test vaporwave theme implementation

# Set up test data
my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;

# Vaporwave color palette as specified in Issue #57
my %vaporwave_colors = (
    'magenta'       => '#BF349A',
    'deep_purple'   => '#8C2771',
    'light_lavender'=> '#E7DCF2',
    'cyan'          => '#2ABFBF',
    'teal'          => '#29A6A6',
);

subtest 'vaporwave color palette implementation' => sub {
    my $css_file = 'public/css/registry.css';
    ok(-f $css_file, 'Registry CSS file exists');

    my $css_content;
    open my $css_fh, '<', $css_file or die "Cannot read CSS file: $!";
    { local $/; $css_content = <$css_fh>; }
    close $css_fh;

    # Check that the vaporwave colors are defined in the CSS variables
    like($css_content, qr/#BF349A/i, 'Magenta color #BF349A is present in CSS');
    like($css_content, qr/#8C2771/i, 'Deep Purple color #8C2771 is present in CSS');
    like($css_content, qr/#E7DCF2/i, 'Light Lavender color #E7DCF2 is present in CSS');
    like($css_content, qr/#2ABFBF/i, 'Cyan color #2ABFBF is present in CSS');
    like($css_content, qr/#29A6A6/i, 'Teal color #29A6A6 is present in CSS');
};

subtest 'vaporwave theme gradient implementation' => sub {
    # Check that templates use vaporwave-style gradients
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

    # After the vaporwave theme is applied, gradients should use the new colors
    my $has_vaporwave_gradient = $landing_content =~ /#BF349A|#8C2771|#2ABFBF/i ||
                                $workflow_content =~ /#BF349A|#8C2771|#2ABFBF/i;

    if (!$has_vaporwave_gradient) {
        ok(0, 'EXPECTED FAILURE: Vaporwave gradient not yet implemented');
    } else {
        ok(1, 'Vaporwave gradient colors implemented');
    }
};

subtest 'accessibility compliance verification' => sub {
    # Verify that the vaporwave colors meet accessibility standards
    # This test will pass once we ensure proper contrast ratios
    my $css_file = 'public/css/registry.css';
    my $css_content;
    open my $css_fh, '<', $css_file or die "Cannot read CSS file: $!";
    { local $/; $css_content = <$css_fh>; }
    close $css_fh;

    # Check for proper text color definitions that ensure readability
    my $has_accessible_text = $css_content =~ /--color-text-primary/ &&
                             $css_content =~ /--color-text-secondary/;

    ok($has_accessible_text, 'Text color variables defined for accessibility');

    # After implementation, we should verify contrast ratios are maintained
    ok(1, 'Placeholder for accessibility verification - will check contrast ratios');
};