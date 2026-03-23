use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is ok like unlike is_deeply subtest use_ok isa_ok can_ok )];
defer { done_testing };

use Test::Mojo;
use Registry;
use Test::Registry::DB;

# ABOUTME: Tests for theme.css design tokens - validates that CSS variables and base typography are served correctly
# ABOUTME: Tests the actual HTTP responses rather than reading CSS files directly

# Set up test database for realistic rendering
my $test_db = Test::Registry::DB->new();
$ENV{DB_URL} = $test_db->uri;

my $t = Test::Mojo->new('Registry');

subtest 'theme.css is properly served' => sub {
    $t->get_ok('/css/theme.css')
      ->status_is(200)
      ->content_type_is('text/css')
      ->content_like(qr/ABOUTME:.*theme/i, 'File has proper ABOUTME header');
};

subtest 'vaporwave color palette is preserved in design tokens' => sub {
    $t->get_ok('/css/theme.css')
      ->status_is(200)
      ->content_like(qr/--color-primary:\s*#BF349A/, 'Primary magenta color preserved')
      ->content_like(qr/--color-primary-dark:\s*#8C2771/, 'Primary dark purple preserved')
      ->content_like(qr/--color-secondary:\s*#2ABFBF/, 'Secondary cyan color preserved')
      ->content_like(qr/--color-gray-50:\s*#E7DCF2/, 'Light lavender background preserved')
      ->content_like(qr/--font-family/, 'Font family design token defined')
      ->content_like(qr/--space-\d+:/, 'Spacing design tokens defined')
      ->content_like(qr/--radius-\w+:/, 'Border radius design tokens defined');
};

subtest 'semantic typography elements are styled' => sub {
    $t->get_ok('/css/theme.css')
      ->status_is(200);

    # Check that heading levels have styling (grouped selector h1, h2, ...)
    $t->content_like(qr/h1[,\s]/, 'h1 element has styles defined')
      ->content_like(qr/h2[,\s]/, 'h2 element has styles defined')
      ->content_like(qr/h3[,\s]/, 'h3 element has styles defined')
      ->content_like(qr/a\s*\{/, 'Link elements have styles')
      ->content_like(qr/strong\s*\{/, 'Strong elements have styles')
      ->content_like(qr/em\s*\{/, 'Emphasis elements have styles')
      ->content_like(qr/small\s*\{/, 'Small elements have styles')
      ->content_like(qr/color:\s*var\(--color-text-/, 'Typography uses color design tokens');
};

subtest 'essential HTMX classes are preserved in app.css' => sub {
    # HTMX classes are in app.css
    $t->get_ok('/css/app.css')
      ->status_is(200)
      ->content_like(qr/\.htmx-indicator\s*\{/, 'htmx-indicator class preserved')
      ->content_like(qr/\.htmx-request/, 'htmx-request class preserved')
      ->content_like(qr/\.hidden\s*\{/, 'hidden utility class preserved')
      ->content_like(qr/\.loading\s*\{/, 'loading utility class preserved')
      ->content_like(qr/\.spinner\s*\{/, 'spinner utility class preserved')
      ->content_like(qr/\.error\s*\{/, 'error state class preserved')
      ->content_like(qr/\.success\s*\{/, 'success state class preserved')
      ->content_like(qr/input\.error/, 'error class works with input elements')
      ->content_like(qr/textarea\.error/, 'error class works with textarea elements');
};

subtest 'button styling with data attributes' => sub {
    $t->get_ok('/css/app.css')
      ->status_is(200)
      ->content_like(qr/\.btn\s*\{/, 'Button utility class base styles defined')
      ->content_like(qr/\.btn-primary/, 'Primary button variant defined')
      ->content_like(qr/\.btn-secondary/, 'Secondary button variant defined')
      ->content_like(qr/background-color:\s*var\(--color-primary\)/, 'Primary buttons use primary color')
      ->content_like(qr/background-color:\s*var\(--color-secondary\)/, 'Secondary buttons use secondary color');
};

subtest 'responsive design with media queries' => sub {
    $t->get_ok('/css/app.css')
      ->status_is(200)
      ->content_like(qr/\@media.*max-width/, 'Responsive media queries defined');
};

subtest 'CSS validation and syntax' => sub {
    my $css_response = $t->get_ok('/css/theme.css')->tx->res->body;

    # Basic CSS syntax validation
    my $open_braces = () = $css_response =~ /\{/g;
    my $close_braces = () = $css_response =~ /\}/g;
    is($open_braces, $close_braces, 'Theme CSS has balanced braces');

    # Check for common CSS syntax errors
    unlike($css_response, qr/;;\s*/, 'No double semicolons in theme CSS');
};

subtest 'design tokens are defined in theme.css' => sub {
    my $theme_response = $t->get_ok('/css/theme.css')->tx->res->body;

    # Extract design tokens from theme.css
    my @theme_tokens = $theme_response =~ /(--[\w-]+):\s*([^;]+);/g;

    my %theme_vars;
    for (my $i = 0; $i < @theme_tokens; $i += 2) {
        $theme_vars{$theme_tokens[$i]} = $theme_tokens[$i + 1];
    }

    # Ensure theme.css has all the essential tokens
    ok(exists $theme_vars{'--color-primary'}, 'Primary color token in theme.css');
    ok(exists $theme_vars{'--font-family'}, 'Font family token in theme.css');
    ok(scalar(keys %theme_vars) > 10, 'Theme.css contains substantial design tokens');

    # Count design token usage in theme.css
    my $token_usage = () = $theme_response =~ /var\(--[\w-]+\)/g;
    ok($token_usage > 10, "Theme CSS uses design tokens (found $token_usage usages)");
};
