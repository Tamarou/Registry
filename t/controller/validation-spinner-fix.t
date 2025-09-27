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

# Test validation spinner behavior via HTTP endpoints

# Set up test data
my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;
my $t = Test::Mojo->new(Registry->new(db => $dao));

subtest 'spinner CSS served via HTTP' => sub {
    # Test that spinner CSS is properly served via HTTP
    $t->get_ok('/css/style.css')
      ->status_is(200)
      ->content_type_is('text/css')
      ->content_like(qr/\.htmx-indicator[^{]*\{[^}]*display:\s*none/, 'Default hidden spinner state served via HTTP CSS');

    # Also check structure.css for spinner styles
    $t->get_ok('/css/structure.css')
      ->status_is(200)
      ->content_type_is('text/css');

    # Use Mojo::File to verify spinner behavior is defined
    my $css_content = Mojo::File->new('public/css/style.css')->slurp;
    like($css_content, qr/\.htmx-indicator/, 'Spinner styles defined in CSS architecture');
};

subtest 'spinner behavior via HTTP CSS validation' => sub {
    # Test spinner behavior states via HTTP
    $t->get_ok('/css/style.css')
      ->content_like(qr/\.htmx-indicator\s*\{[^}]*display:\s*none/, 'Hidden default state served via HTTP')
      ->content_like(qr/\.htmx-indicator\.(htmx-request|active)/, 'Active spinner state defined in served CSS');

    # Use Mojo::File for detailed behavior verification
    my $css_content = Mojo::File->new('public/css/style.css')->slurp;

    my $has_hidden_default = $css_content =~ /\.htmx-indicator\s*\{[^}]*display:\s*none/;
    my $has_active_state = $css_content =~ /\.htmx-indicator\.(htmx-request|active)\s*\{[^}]*display:\s*(flex|block)/ ||
                          $css_content =~ /\.htmx-indicator\.(htmx-request|active)\s*\{[^}]*opacity:\s*1/;

    ok($has_hidden_default, 'Spinner hidden by default in CSS');
    ok($has_active_state, 'Spinner visible during HTMX requests in CSS');

    my $has_correct_behavior = $has_hidden_default && $has_active_state;
    ok($has_correct_behavior, 'Complete spinner behavior implemented via CSS architecture');
};