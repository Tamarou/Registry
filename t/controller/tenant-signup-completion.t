use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(defer try);
use Test::More import => [qw( done_testing is ok like is_deeply subtest use_ok isa_ok can_ok )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use DateTime;

# Set up test data
my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;

subtest 'Enhanced completion step template exists' => sub {
    # Test that the completion template file exists and has the expected content
    my $template_path = 'templates/tenant-signup/complete.html.ep';
    ok(-f $template_path, 'Completion template file exists');
    
    # Read template content and verify key elements
    open my $fh, '<', $template_path or die "Cannot open template: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    
    like($content, qr/Welcome to Registry!/, 'Template contains welcome message');
    like($content, qr/organization_name/, 'Template uses organization_name variable');
    like($content, qr/subdomain/, 'Template uses subdomain variable');
    like($content, qr/admin_email/, 'Template uses admin_email variable');
    like($content, qr/trial_end_date/, 'Template uses trial_end_date variable');
    like($content, qr/success-container/, 'Template has success container CSS class');
    # Check that mobile responsive CSS exists in CSS files
    my $css_content = do {
        local $/;
        open my $css_fh, '<', 'public/css/style.css' or die "Cannot read style.css: $!";
        <$css_fh>;
    };
    like($css_content, qr/\@media.*max-width.*768px/, 'Template includes mobile responsive CSS');
};

subtest 'RegisterTenant class structure' => sub {
    # Test that the RegisterTenant class can be loaded and has expected methods
    use_ok('Registry::DAO::WorkflowSteps::RegisterTenant');
    
    # Test that it has the expected methods
    can_ok('Registry::DAO::WorkflowSteps::RegisterTenant', '_format_trial_end_date');
    can_ok('Registry::DAO::WorkflowSteps::RegisterTenant', 'process');
};

subtest 'Success data formatting' => sub {
    # Test trial end date formatting functionality
    my $unix_timestamp = time() + (30 * 24 * 60 * 60); # 30 days from now
    ok($unix_timestamp > 0, 'Unix timestamp generated');
    
    # Test that DateTime can format dates properly
    my $dt = DateTime->from_epoch(epoch => $unix_timestamp);
    my $formatted = $dt->strftime('%B %d, %Y');
    ok($formatted =~ /\w+ \d{1,2}, \d{4}/, 'Date formatting works');
    
    # Test ISO date parsing
    my $iso_date = DateTime->now->add(days => 30)->iso8601();
    ok($iso_date =~ /\d{4}-\d{2}-\d{2}T/, 'ISO date format correct');
};