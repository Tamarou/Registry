use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is ok like unlike is_deeply subtest use_ok isa_ok can_ok )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use DateTime;
use Registry::Utility::BaseDomain ();

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
    
    like($content, qr/Your studio is live/, 'Template contains welcome message');
    like($content, qr/organization_name/, 'Template uses organization_name variable');
    like($content, qr/subdomain/, 'Template uses subdomain variable');
    like($content, qr/admin_email/, 'Template uses admin_email variable');
    like($content, qr/tenant_url/, 'Template builds links from the configured base domain');

    # A tenant who never finds the payments screen cannot be paid, and the
    # refusal they eventually hit is on a different page entirely (#439).
    like($content, qr{/admin/billing},
        'Template points the new tenant at Stripe Connect onboarding');
    like($content, qr/success-container/, 'Template has success container CSS class');

    # The page handed a new tenant four links, all to <slug>.registry.localhost,
    # a hostname that resolves on a developer's machine and nowhere else.
    unlike($content, qr/registry\.localhost/,
        'Template does not hardcode a development hostname');
    # And it promised a 30-day trial ending on a date, plus a \$200/month
    # subscription starting after it, to a tenant on a plan that is free forever.
    unlike($content, qr/trial/i, 'Template does not promise a trial');
    unlike($content, qr/\\\$200/, 'Template does not quote a retired monthly price');
    # Check that mobile responsive CSS exists in CSS files
    my $css_content = do {
        local $/;
        open my $css_fh, '<', 'public/css/app.css' or die "Cannot read app.css: $!";
        <$css_fh>;
    };
    like($css_content, qr/\@media.*max-width.*768px/, 'Template includes mobile responsive CSS');
};

subtest 'RegisterTenant class structure' => sub {
    # Test that the RegisterTenant class can be loaded and has expected methods
    use_ok('Registry::DAO::WorkflowSteps::RegisterTenant');
    
    # Test that it has the expected methods
    can_ok('Registry::DAO::WorkflowSteps::RegisterTenant', 'prepare_completion_data');
    can_ok('Registry::DAO::WorkflowSteps::RegisterTenant', 'process');
};

subtest 'completion links point at the configured base domain' => sub {
    local $ENV{REGISTRY_BASE_DOMAINS} = 'example.test';
    is Registry::Utility::BaseDomain::tenant_url('acme', '/login'),
        'https://acme.example.test/login',
        'a tenant link is built from REGISTRY_BASE_DOMAINS, not a literal';
};