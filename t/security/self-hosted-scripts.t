# ABOUTME: Pins htmx and chart.js to self-hosted copies under public/js/vendor/.
# ABOUTME: No template may load them from a CDN, and the CSP must not allow one.
use 5.42.0;
use lib          qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing subtest ok is like unlike )];
defer { done_testing };

use Test::Registry::DB;
use Mojo::File qw(path);
use Test::Mojo;

my $test_db = Test::Registry::DB->new();
$ENV{DB_URL} = $test_db->db->url;
my $t = Test::Mojo->new('Registry');

my $vendor = path('public/js/vendor');

# README rows look like: | htmx.min.js | htmx.org | 2.0.3 | ... |
my %recorded = map { /^\|\s*(\S+\.js)\s*\|\s*\S+\s*\|\s*(\d+\.\d+\.\d+)\s*\|/ ? ( $1 => $2 ) : () }
  split /\n/, eval { $vendor->child('README.md')->slurp('UTF-8') } // '';

subtest 'no template loads code from unpkg or jsdelivr' => sub {
    my @hits;
    for my $file ( path('templates')->list_tree->grep(qr/\.ep$/)->each ) {
        my $n = 0;
        for my $line ( split /\n/, $file->slurp('UTF-8') ) {
            $n++;
            push @hits, "$file:$n" if $line =~ /unpkg\.com|cdn\.jsdelivr\.net/;
        }
    }
    is "@hits", '', 'no template references unpkg.com or cdn.jsdelivr.net';
};

subtest 'CSP script-src allows Stripe but no public CDN' => sub {
    $t->get_ok('/js/vendor/htmx.min.js');
    my ($script_src) =
      ( $t->tx->res->headers->header('Content-Security-Policy') // '' ) =~ /(?:^|;\s*)(script-src[^;]*)/;
    ok $script_src, 'CSP has a script-src directive';
    unlike $script_src // '', qr/unpkg\.com/,        'script-src does not allow unpkg.com';
    unlike $script_src // '', qr/cdn\.jsdelivr\.net/, 'script-src does not allow cdn.jsdelivr.net';
    like $script_src // '', qr/\bjs\.stripe\.com\b/, 'script-src still allows js.stripe.com';
};

subtest 'vendored scripts are served locally' => sub {
    for my $file (qw(htmx.min.js chart.umd.min.js)) {
        $t->get_ok("/js/vendor/$file")->status_is(200)
          ->content_type_like( qr{^(?:application|text)/javascript}, "$file served as JavaScript" );
    }
};

subtest 'htmx version is pinned' => sub {
    my ($in_file) = $vendor->child('htmx.min.js')->slurp =~ /\bversion:"([^"]+)"/;
    ok $recorded{'htmx.min.js'}, 'README records the htmx version';
    is $in_file, $recorded{'htmx.min.js'}, 'htmx.min.js is the version README records';
};

subtest 'chart.js version is pinned' => sub {
    my ($in_file) = $vendor->child('chart.umd.min.js')->slurp =~ /Chart\.js v(\d+\.\d+\.\d+)/;
    ok $recorded{'chart.umd.min.js'}, 'README records the chart.js version';
    is $in_file, $recorded{'chart.umd.min.js'}, 'chart.umd.min.js is the version README records';
};
