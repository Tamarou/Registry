use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(defer try);
use Test::More import => [qw( done_testing is ok like unlike is_deeply subtest use_ok isa_ok can_ok )];
defer { done_testing };

use Test::Mojo;
use Registry;
use Test::Registry::DB;

# ABOUTME: Tests for CSS structure integration - validates that CSS is properly linked and semantic HTML is rendered
# ABOUTME: Tests the actual rendered content rather than reading CSS files directly

# Set up test database for realistic rendering
my $test_db = Test::Registry::DB->new();
$ENV{DB_URL} = $test_db->uri;

my $t = Test::Mojo->new('Registry');

subtest 'CSS files are properly linked in templates' => sub {
    # Test default layout includes style.css
    $t->get_ok('/')
      ->status_is(200)
      ->element_exists('link[href="/css/style.css"]', 'style.css is linked in default layout')
      ->element_exists('head link[rel="stylesheet"]', 'CSS link has proper rel attribute');
};

subtest 'semantic HTML structure is rendered correctly' => sub {
    # Test that semantic HTML5 elements are present
    # Note: The landing page uses a custom layout, not the default container structure
    $t->get_ok('/')
      ->status_is(200)
      ->element_exists('html[lang="en"]', 'HTML has lang attribute')
      ->element_exists('head meta[charset="utf-8"]', 'UTF-8 charset is set')
      ->element_exists('head meta[name="viewport"]', 'Viewport meta tag is present')
      ->element_exists('head title', 'Title element is present')
      ->element_exists('body', 'Body element is present')
      ->element_exists('div.landing-page', 'Landing page container is present')
      ->element_exists('section[role="banner"]', 'Semantic header section is present')
      ->element_exists('section[role="main"]', 'Semantic main section is present');
};

subtest 'teacher layout uses semantic HTML5 structure' => sub {
    # We need to test teacher layout, but it requires authentication
    # For now, let's test that the template renders the expected structure
    # by checking if the CSS classes that should be applied are present in templates
    my $teacher_template = do {
        local $/;
        open my $fh, '<', 'templates/layouts/teacher.html.ep' or die "Cannot read teacher template: $!";
        <$fh>;
    };

    like($teacher_template, qr/<article/, 'Teacher layout uses semantic article element');
    like($teacher_template, qr/<header/, 'Teacher layout uses semantic header element');
    like($teacher_template, qr/<main/, 'Teacher layout uses semantic main element');
    like($teacher_template, qr/class="teacher-/, 'Teacher layout uses teacher-specific CSS classes');
    like($teacher_template, qr/href="\/css\/style\.css"/, 'Teacher layout links to style.css');
};

subtest 'responsive design meta tags are present' => sub {
    $t->get_ok('/')
      ->status_is(200)
      ->element_exists('meta[name="viewport"][content*="width=device-width"]', 'Responsive viewport meta tag is present')
      ->element_exists('meta[name="viewport"][content*="initial-scale=1"]', 'Initial scale is set for mobile');
};

subtest 'semantic templates use proper HTML5 structure' => sub {
    # Test that converted templates use semantic HTML
    my @semantic_templates = (
        'templates/tenant-signup/payment.html.ep',
        'templates/tenant-signup/complete.html.ep',
        'templates/tenant-signup/users.html.ep'
    );

    for my $template_path (@semantic_templates) {
        next unless -f $template_path;

        my $template_content = do {
            local $/;
            open my $fh, '<', $template_path or die "Cannot read $template_path: $!";
            <$fh>;
        };

        # Check for semantic HTML5 elements
        like($template_content, qr/<(section|article|header|main|aside|footer)/,
             "$template_path uses semantic HTML5 elements");

        # Check that no inline <style> tags remain
        unlike($template_content, qr/<style[^>]*>.*?<\/style>/s,
               "$template_path has no embedded CSS styles");
    }
};

subtest 'CSS architecture supports design token usage' => sub {
    # Instead of parsing CSS files, test that the rendered content
    # indicates the CSS is working properly by checking for CSS classes
    # that would only work if the design tokens are properly defined

    $t->get_ok('/')
      ->status_is(200)
      ->element_exists('.landing-page', 'Landing page container class is available')
      ->element_exists('section[role="banner"]', 'Semantic header section renders');

    # We can indirectly test that design tokens work by verifying
    # the CSS file exists and is accessible via HTTP
    $t->get_ok('/css/style.css')
      ->status_is(200)
      ->content_like(qr/structure\.css/, 'style.css imports structure.css')
      ->content_like(qr/--color-primary/, 'CSS contains design token references');

    $t->get_ok('/css/structure.css')
      ->status_is(200)
      ->content_like(qr/--color-primary:\s*#BF349A/, 'Primary vaporwave color is defined')
      ->content_like(qr/--color-secondary:\s*#2ABFBF/, 'Secondary vaporwave color is defined')
      ->content_like(qr/--font-family:/, 'Font family design token is defined')
      ->content_like(qr/--space-\d+:/, 'Spacing design tokens are defined');
};

subtest 'HTMX integration works with CSS' => sub {
    # Test that HTMX-related CSS classes are available
    $t->get_ok('/css/style.css')
      ->status_is(200)
      ->content_like(qr/\.htmx-indicator/, 'HTMX indicator class is defined')
      ->content_like(qr/\.hidden/, 'Hidden utility class is defined')
      ->content_like(qr/\.loading/, 'Loading utility class is defined')
      ->content_like(qr/\.spinner/, 'Spinner utility class is defined');
};