use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(defer try);
use Test::More import => [qw( done_testing is ok like unlike is_deeply subtest use_ok isa_ok can_ok )];
defer { done_testing };

use Test::Mojo;
use Registry;
use Test::Registry::DB;

# ABOUTME: Tests for semantic HTML styling integration - validates that semantic elements receive proper styling
# ABOUTME: Tests the actual rendered content and HTTP responses rather than reading CSS files directly

# Set up test database for realistic rendering
my $test_db = Test::Registry::DB->new();
$ENV{DB_URL} = $test_db->uri;

my $t = Test::Mojo->new('Registry');

subtest 'structure.css provides semantic HTML styling' => sub {
    $t->get_ok('/css/structure.css')
      ->status_is(200)
      ->content_type_is('text/css')
      ->content_like(qr/ABOUTME:.*structure.*CSS/i, 'File has proper ABOUTME header')
      ->content_like(qr/ABOUTME:.*semantic.*HTML/i, 'File explains semantic HTML approach');
};

subtest 'vaporwave color palette is preserved in design tokens' => sub {
    $t->get_ok('/css/structure.css')
      ->status_is(200)
      ->content_like(qr/--color-primary:\s*#BF349A/, 'Primary magenta color preserved')
      ->content_like(qr/--color-primary-dark:\s*#8C2771/, 'Primary dark purple preserved')
      ->content_like(qr/--color-secondary:\s*#2ABFBF/, 'Secondary cyan color preserved')
      ->content_like(qr/--color-gray-50:\s*#E7DCF2/, 'Light lavender background preserved')
      ->content_like(qr/--font-family:/, 'Font family design token defined')
      ->content_like(qr/--space-\d+:/, 'Spacing design tokens defined')
      ->content_like(qr/--radius-\w+:/, 'Border radius design tokens defined');
};

subtest 'semantic typography elements are styled' => sub {
    $t->get_ok('/css/structure.css')
      ->status_is(200);

    # Check that all heading levels have styling
    for my $level (1..6) {
        $t->content_like(qr/h$level[,\s\{]/, "h$level element has styles defined");
    }

    # Check paragraph and text element styles
    $t->content_like(qr/p[,\s\{]/, 'Paragraph elements have styles')
      ->content_like(qr/a[,\s\{]/, 'Link elements have styles')
      ->content_like(qr/strong[,\s\{]/, 'Strong elements have styles')
      ->content_like(qr/em[,\s\{]/, 'Emphasis elements have styles')
      ->content_like(qr/small[,\s\{]/, 'Small elements have styles')
      ->content_like(qr/font-size:\s*var\(--font-size-/, 'Typography uses font-size design tokens')
      ->content_like(qr/color:\s*var\(--color-text-/, 'Typography uses color design tokens');
};

subtest 'semantic form elements are styled' => sub {
    $t->get_ok('/css/structure.css')
      ->status_is(200)
      # Check basic form elements (they can be grouped with commas)
      ->content_like(qr/input[,\s\{]/, 'Input elements have base styles')
      ->content_like(qr/textarea[,\s\{]/, 'Textarea elements have styles')
      ->content_like(qr/select[,\s\{]/, 'Select elements have styles')
      ->content_like(qr/button[,\s\{]/, 'Button elements have styles')
      ->content_like(qr/label[,\s\{]/, 'Label elements have styles')
      # Check specific input types
      ->content_like(qr/input\[type=["\']text["\']/, 'Text input styling defined')
      ->content_like(qr/input\[type=["\']email["\']/, 'Email input styling defined')
      ->content_like(qr/input\[type=["\']tel["\']/, 'Tel input styling defined')
      # Check form focus states
      ->content_like(qr/input:focus/, 'Input focus states defined')
      ->content_like(qr/textarea:focus/, 'Textarea focus states defined')
      ->content_like(qr/select:focus/, 'Select focus states defined')
      # Check that form elements use design tokens
      ->content_like(qr/border:\s*.*var\(--/, 'Form elements use border design tokens')
      ->content_like(qr/border-radius:\s*var\(--radius-/, 'Form elements use radius design tokens')
      ->content_like(qr/padding:\s*var\(--space-/, 'Form elements use spacing design tokens');
};

subtest 'semantic button styling with data attributes' => sub {
    $t->get_ok('/css/structure.css')
      ->status_is(200)
      ->content_like(qr/button[,\s\{]/, 'Button base styles defined')
      # Check button variants via data attributes (classless approach)
      ->content_like(qr/button\[data-variant=["\']primary["\']/, 'Primary button variant with data attribute')
      ->content_like(qr/button\[data-variant=["\']secondary["\']/, 'Secondary button variant with data attribute')
      ->content_like(qr/button\[data-variant=["\']success["\']/, 'Success button variant with data attribute')
      ->content_like(qr/button\[data-variant=["\']danger["\']/, 'Danger button variant with data attribute')
      # Check button sizes via data attributes
      ->content_like(qr/button\[data-size=["\']sm["\']/, 'Small button size with data attribute')
      ->content_like(qr/button\[data-size=["\']lg["\']/, 'Large button size with data attribute')
      # Check button states
      ->content_like(qr/button:hover/, 'Button hover states defined')
      ->content_like(qr/button:focus/, 'Button focus states defined')
      ->content_like(qr/button:disabled/, 'Button disabled states defined')
      # Check that buttons use vaporwave colors
      ->content_like(qr/background-color:\s*var\(--color-primary\)/, 'Primary buttons use primary color')
      ->content_like(qr/background-color:\s*var\(--color-secondary\)/, 'Secondary buttons use secondary color');
};

subtest 'essential HTMX classes are preserved in style.css' => sub {
    # HTMX classes are in style.css, not structure.css
    $t->get_ok('/css/style.css')
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

subtest 'semantic layout elements are styled' => sub {
    $t->get_ok('/css/structure.css')
      ->status_is(200)
      ->content_like(qr/header[,\s\{]/, 'Header element styling defined')
      ->content_like(qr/main[,\s\{]/, 'Main element styling defined')
      ->content_like(qr/section[,\s\{]/, 'Section element styling defined')
      ->content_like(qr/article[,\s\{]/, 'Article element styling defined')
      ->content_like(qr/aside[,\s\{]/, 'Aside element styling defined')
      ->content_like(qr/footer[,\s\{]/, 'Footer element styling defined')
      ->content_like(qr/margin:\s*var\(--space-/, 'Layout uses spacing design tokens')
      ->content_like(qr/padding:\s*var\(--space-/, 'Layout uses padding design tokens');
};

subtest 'responsive design with semantic elements' => sub {
    $t->get_ok('/css/structure.css')
      ->status_is(200)
      ->content_like(qr/\@media.*max-width/, 'Responsive media queries defined')
      ->content_like(qr/\@media.*?h1\s*\{.*?\}/s, 'H1 responsive scaling defined')
      ->content_like(qr/\@media.*?h2\s*\{.*?\}/s, 'H2 responsive scaling defined')
      ->content_like(qr/\@media.*?input.*?\}/s, 'Input responsive scaling defined')
      ->content_like(qr/\@media.*?button.*?\}/s, 'Button responsive scaling defined');
};

subtest 'CSS validation and syntax' => sub {
    my $css_response = $t->get_ok('/css/structure.css')->tx->res->body;

    # Basic CSS syntax validation
    my $open_braces = () = $css_response =~ /\{/g;
    my $close_braces = () = $css_response =~ /\}/g;
    is($open_braces, $close_braces, 'CSS has balanced braces');

    # Check for common CSS syntax errors
    unlike($css_response, qr/;;\s*/, 'No double semicolons');
    unlike($css_response, qr/\{\s*\}/, 'No empty CSS rules');

    # Check that selectors are valid (no leading dots on semantic elements)
    unlike($css_response, qr/\.h[1-6]\s*\{/, 'No class selectors for headings (should be semantic)');
    unlike($css_response, qr/\.p\s*\{/, 'No class selector for paragraphs (should be semantic)');
    unlike($css_response, qr/\.button\s*\{/, 'No class selector for buttons (should be semantic)');
};

subtest 'design token consistency between CSS files' => sub {
    my $style_response = $t->get_ok('/css/style.css')->tx->res->body;
    my $structure_response = $t->get_ok('/css/structure.css')->tx->res->body;

    # Extract design tokens from both files
    my @structure_tokens = $structure_response =~ /(--[\w-]+):\s*([^;]+);/g;
    my @style_tokens = $style_response =~ /(--[\w-]+):\s*([^;]+);/g;

    my %structure_vars;
    for (my $i = 0; $i < @structure_tokens; $i += 2) {
        $structure_vars{$structure_tokens[$i]} = $structure_tokens[$i + 1];
    }

    # Style.css should have minimal token definitions (should import from structure.css)
    is(scalar(@style_tokens), 0, 'No design token definitions in style.css (should import from structure.css)');

    # Ensure structure.css has all the essential tokens
    ok(exists $structure_vars{'--color-primary'}, 'Primary color token in structure.css');
    ok(exists $structure_vars{'--font-family'}, 'Font family token in structure.css');
    ok(scalar(keys %structure_vars) > 10, 'Structure.css contains substantial design tokens');

    # Count design token usage in structure.css
    my $token_usage = () = $structure_response =~ /var\(--[\w-]+\)/g;
    ok($token_usage > 20, "Structure CSS uses design tokens extensively (found $token_usage usages)");
};