use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(defer try);
use Test::More import => [qw( done_testing is ok like is_deeply subtest use_ok isa_ok can_ok )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;
use Test::Registry::Fixtures;

# Test validation spinner behavior in tenant profile step

# Set up test data
my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;

subtest 'tenant profile template spinner elements' => sub {
    # Test that the profile template has the correct HTML elements for the validation spinner
    my $template_path = 'templates/tenant-signup/profile.html.ep';
    my $css_file = 'public/css/registry.css';

    ok(-f $template_path, 'Profile template file exists');
    ok(-f $css_file, 'CSS file exists');

    my $template_content;
    open my $template_fh, '<', $template_path or die "Cannot read template: $!";
    { local $/; $template_content = <$template_fh>; }
    close $template_fh;

    my $css_content;
    open my $css_fh, '<', $css_file or die "Cannot read CSS file: $!";
    { local $/; $css_content = <$css_fh>; }
    close $css_fh;

    # Check that spinner element exists with proper class in template
    like($template_content, qr/<div[^>]*id="form-spinner"[^>]*class="[^"]*htmx-indicator[^"]*"/, 'Spinner has htmx-indicator class');

    # Check that template does NOT have embedded CSS (uses external file)
    my $template_has_embedded_css = $template_content =~ /<style[^>]*>/;
    ok(!$template_has_embedded_css, 'Template does not have embedded CSS - uses external file');

    # Check that CSS file has the spinner styles
    like($css_content, qr/\.htmx-indicator[^{]*\{[^}]*display:\s*none/, 'CSS file defines default hidden state for spinner');
};

subtest 'spinner CSS behavior verification' => sub {
    # Verify that the spinner CSS is correctly defined in the external CSS file
    my $css_file = 'public/css/registry.css';

    my $css_content;
    open my $css_fh, '<', $css_file or die "Cannot read CSS file: $!";
    { local $/; $css_content = <$css_fh>; }
    close $css_fh;

    # Check that CSS defines proper spinner behavior
    my $has_hidden_default = $css_content =~ /\.htmx-indicator\s*\{[^}]*display:\s*none/;
    my $has_active_state = $css_content =~ /\.htmx-indicator\.htmx-request\s*\{[^}]*display:\s*flex/ ||
                          $css_content =~ /\.htmx-indicator\.htmx-request\s*\{[^}]*opacity:\s*1/;

    ok($has_hidden_default, 'CSS defines spinner as hidden by default');
    ok($has_active_state, 'CSS defines spinner as visible during HTMX requests');

    # Verify we have both states properly defined
    my $has_correct_behavior = $has_hidden_default && $has_active_state;
    ok($has_correct_behavior, 'Spinner CSS behavior is correctly implemented');
};