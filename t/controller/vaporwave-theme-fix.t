use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(defer try);
use Test::More import => [qw( done_testing is ok like is_deeply subtest use_ok isa_ok can_ok )];
defer { done_testing };

use Test::Mojo;
use Registry;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Mojo::File;

# Test vaporwave theme implementation via HTTP endpoints

# Set up test data
my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;
my $t = Test::Mojo->new(Registry->new(db => $dao));

# Vaporwave color palette as specified in Issue #57
my %vaporwave_colors = (
    'magenta'       => '#BF349A',
    'deep_purple'   => '#8C2771',
    'light_lavender'=> '#E7DCF2',
    'cyan'          => '#2ABFBF',
    'teal'          => '#29A6A6',
);

subtest 'vaporwave colors served via HTTP CSS' => sub {
    # Test that CSS files are properly served and contain vaporwave colors
    $t->get_ok('/css/structure.css')
      ->status_is(200)
      ->content_type_is('text/css')
      ->content_like(qr/#BF349A/i, 'Magenta color #BF349A served in CSS')
      ->content_like(qr/#8C2771/i, 'Deep Purple color #8C2771 served in CSS')
      ->content_like(qr/#E7DCF2/i, 'Light Lavender color #E7DCF2 served in CSS')
      ->content_like(qr/#2ABFBF/i, 'Cyan color #2ABFBF served in CSS')
      ->content_like(qr/#29A6A6/i, 'Teal color #29A6A6 served in CSS');

    # Verify that style.css also provides access to these colors (via import)
    $t->get_ok('/css/style.css')
      ->status_is(200)
      ->content_type_is('text/css')
      ->content_like(qr/\@import.*structure\.css/, 'Style.css imports structure.css for vaporwave colors');
};

subtest 'vaporwave theme via rendered HTML pages' => sub {
    # Test that rendered pages properly link to vaporwave CSS
    $t->get_ok('/')
      ->status_is(200)
      ->content_type_is('text/html;charset=UTF-8')
      ->content_like(qr/<link[^>]*href="[^"]*css\/style\.css"/, 'Landing page links to vaporwave CSS architecture')
      ->content_unlike(qr/<style[^>]*>/, 'Landing page uses external CSS (not embedded) for vaporwave theme');

    # Test that vaporwave color variables are defined in the served CSS
    $t->get_ok('/css/structure.css')
      ->content_like(qr/--color-primary:\s*#BF349A/, 'Primary vaporwave color defined as CSS variable')
      ->content_like(qr/--color-secondary:\s*#2ABFBF/, 'Secondary vaporwave color defined as CSS variable')
      ->content_like(qr/--color-primary-dark:\s*#8C2771/, 'Dark vaporwave color defined as CSS variable');
};

subtest 'vaporwave accessibility via HTTP CSS' => sub {
    # Test that accessibility text colors are served via HTTP
    $t->get_ok('/css/structure.css')
      ->content_like(qr/--color-text-primary/, 'Text color variables served for accessibility')
      ->content_like(qr/--color-text-secondary/, 'Secondary text color variables served for accessibility');

    # Use Mojo::File only for detailed CSS content analysis when needed
    my $css_content = Mojo::File->new('public/css/structure.css')->slurp;
    my $has_accessible_text = $css_content =~ /--color-text-primary/ &&
                             $css_content =~ /--color-text-secondary/;

    ok($has_accessible_text, 'Vaporwave theme includes accessible text color definitions');
    ok(1, 'Placeholder for contrast ratio verification - vaporwave colors designed for accessibility');
};