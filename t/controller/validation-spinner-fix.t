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

subtest 'tenant profile template spinner CSS' => sub {
    # Test that the profile template has the correct CSS for the validation spinner
    my $template_path = 'templates/tenant-signup/profile.html.ep';
    ok(-f $template_path, 'Profile template file exists');

    my $content;
    open my $fh, '<', $template_path or die "Cannot read template: $!";
    { local $/; $content = <$fh>; }
    close $fh;

    # Check that spinner element exists with proper class
    like($content, qr/<div[^>]*id="form-spinner"[^>]*class="[^"]*htmx-indicator[^"]*"/, 'Spinner has htmx-indicator class');

    # Check for existing CSS rules - these tests will fail initially, showing the issue
    like($content, qr/\.htmx-indicator[^{]*\{[^}]*display:\s*none/, 'Default hidden state defined') ||
        ok(0, 'EXPECTED FAILURE: htmx-indicator missing default hidden state - this is the bug we need to fix');
};

subtest 'spinner behavior verification' => sub {
    # Verify that the spinner should be hidden by default and shown during requests
    my $template_path = 'templates/tenant-signup/profile.html.ep';
    my $content;
    open my $fh, '<', $template_path or die "Cannot read template: $!";
    { local $/; $content = <$fh>; }
    close $fh;

    # This test documents what the CSS should look like after our fix
    my $has_correct_css = $content =~ /\.htmx-indicator\s*\{[^}]*display:\s*none/ &&
                         $content =~ /\.htmx-indicator\.htmx-request\s*\{[^}]*opacity:\s*1/;

    if (!$has_correct_css) {
        ok(0, 'CSS rules need to be fixed - spinner not properly hidden by default');
    } else {
        ok(1, 'CSS rules are correct');
    }
};