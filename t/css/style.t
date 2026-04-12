use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is ok like unlike is_deeply subtest use_ok isa_ok can_ok )];
defer { done_testing };

use Test::Mojo;
use Registry;
use Test::Registry::DB;
use Test::Registry::Helpers qw(import_all_workflows);

# ABOUTME: Tests for app.css integration - validates utility classes and component styles work in rendered content
# ABOUTME: Tests the actual rendered content and HTTP responses rather than reading CSS files directly

# Set up test database for realistic rendering
my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

import_all_workflows($dao);

my $t = Test::Mojo->new('Registry');

subtest 'app.css is properly served' => sub {
    $t->get_ok('/css/app.css')
      ->status_is(200)
      ->content_type_is('text/css')
      ->content_like(qr/ABOUTME:.*application.*CSS/i, 'File has proper ABOUTME header');
};

subtest 'utility classes are available in rendered content' => sub {
    # Test that pages can use utility classes by checking they render without errors
    $t->get_ok('/')
      ->status_is(200)
      ->element_exists('.landing-page', 'Landing page container class is used')
      ->element_exists('.landing-nav', 'Landing nav class is used');

    # Test that CSS contains expected utility classes
    $t->get_ok('/css/app.css')
      ->status_is(200)
      ->content_like(qr/\.btn\s*\{/, 'Button utility class is defined')
      ->content_like(qr/\.card\s*\{/, 'Card utility class is defined')
      ->content_like(qr/\.container\s*\{/, 'Container utility class is defined')
      ->content_like(qr/\.btn-primary/, 'Primary button variant is defined')
      ->content_like(qr/\.btn-secondary/, 'Secondary button variant is defined');
};

subtest 'design tokens are used throughout app.css' => sub {
    $t->get_ok('/css/app.css')
      ->status_is(200)
      ->content_like(qr/var\(--color-primary\)/, 'Uses primary color design token')
      ->content_like(qr/var\(--color-secondary\)/, 'Uses secondary color design token')
      ->content_like(qr/var\(--space-\d+\)/, 'Uses spacing design tokens')
      ->content_like(qr/var\(--font-size-\w+\)/, 'Uses font size design tokens')
      ->content_like(qr/var\(--radius-\w+\)/, 'Uses border radius design tokens');

    # Count token usage
    my $css_response = $t->get_ok('/css/app.css')->tx->res->body;
    my $token_count = () = $css_response =~ /var\(--[\w-]+\)/g;
    ok($token_count > 100, "App.css uses design tokens extensively (found $token_count usages)");
};

subtest 'HTMX integration classes are available' => sub {
    $t->get_ok('/css/app.css')
      ->status_is(200)
      ->content_like(qr/\.htmx-indicator/, 'HTMX indicator class is defined')
      ->content_like(qr/\.htmx-request/, 'HTMX request class is defined')
      ->content_like(qr/\.hidden/, 'Hidden utility class is defined')
      ->content_like(qr/\.loading/, 'Loading utility class is defined')
      ->content_like(qr/\.spinner/, 'Spinner utility class is defined')
      ->content_like(qr/\.error/, 'Error state class is defined')
      ->content_like(qr/\.success/, 'Success state class is defined');
};

subtest 'responsive design utilities are available' => sub {
    $t->get_ok('/css/app.css')
      ->status_is(200)
      ->content_like(qr/\@media.*max-width.*768px/, 'Mobile breakpoint media query is defined')
      ->content_like(qr/\.d-flex/, 'Display utility classes are defined')
      ->content_like(qr/\.justify-center/, 'Flexbox utility classes are defined')
      ->content_like(qr/\.text-center/, 'Text alignment utilities are defined')
      ->content_like(qr/\.btn-lg/, 'Button size variants are defined');
};

subtest 'page-specific styles are included' => sub {
    $t->get_ok('/css/app.css')
      ->status_is(200)
      ->content_like(qr/\.teacher-/, 'Teacher-specific styles are defined')
      ->content_like(qr/\.payment-/, 'Payment page styles are defined')
      ->content_like(qr/\.success-/, 'Success page styles are defined')
      ->content_like(qr/\.marketing/, 'Marketing page styles are defined')
      ->content_like(qr/\.hero/, 'Hero section styles are defined')
      ->content_like(qr/\.features/, 'Features section styles are defined');
};

subtest 'CSS has proper syntax and structure' => sub {
    my $css_response = $t->get_ok('/css/app.css')->tx->res->body;

    # Basic CSS syntax validation
    my $open_braces = () = $css_response =~ /\{/g;
    my $close_braces = () = $css_response =~ /\}/g;
    is($open_braces, $close_braces, 'CSS has balanced braces');

    # Check for common CSS syntax errors
    unlike($css_response, qr/;;\s*/, 'No double semicolons');
    unlike($css_response, qr/\{\s*\}/, 'No empty CSS rules');
};

subtest 'backward compatibility classes are preserved' => sub {
    $t->get_ok('/css/app.css')
      ->status_is(200)
      ->content_like(qr/\.btn/, 'Button utility classes preserved')
      ->content_like(qr/\.text-/, 'Text utility classes preserved')
      ->content_like(qr/\.bg-/, 'Background utility classes preserved')
      ->content_like(qr/\.p-\d/, 'Padding utility classes preserved')
      ->content_like(qr/\.m-\d/, 'Margin utility classes preserved')
      ->content_like(qr/\.d-/, 'Display utility classes preserved')
      ->content_like(qr/\.flex/, 'Flexbox utility classes preserved');
};
