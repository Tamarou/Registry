# ABOUTME: Tests that security headers are present on all response types.
# ABOUTME: Verifies X-Frame-Options, CSP, X-Content-Type-Options, X-XSS-Protection.
use 5.42.0;
use lib          qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing subtest ok is like )];
defer { done_testing };

use Test::Registry::DB;
use Registry::DAO;
use Mojo::Home;
use YAML::XS qw(Load);

# Setup test database
my $test_db = Test::Registry::DB->new();
my $dao     = $test_db->db;

# Import workflows so routes work
my $workflow_dir = Mojo::Home->new->child('workflows');
my @files        = $workflow_dir->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load( $file->slurp )->{draft};
    Workflow->from_yaml( $dao, $file->slurp );
}

$ENV{DB_URL} = $dao->url;

use Test::Mojo;
my $t = Test::Mojo->new('Registry');

# Helper to check all required security headers on a response
sub check_security_headers {
    my ( $label, $tx ) = @_;
    my $headers = $tx->res->headers;

    subtest "Security headers present on $label" => sub {
        is $headers->header('X-Frame-Options'),
          'DENY',
          'X-Frame-Options is DENY';

        is $headers->header('X-Content-Type-Options'),
          'nosniff',
          'X-Content-Type-Options is nosniff';

        is $headers->header('X-XSS-Protection'),
          '0',
          'X-XSS-Protection is 0 (rely on CSP)';

        my $csp = $headers->header('Content-Security-Policy');
        ok $csp, 'Content-Security-Policy header present';
        like $csp, qr/default-src 'self'/,   'CSP has default-src self';
        like $csp, qr/js\.stripe\.com/,       'CSP allows js.stripe.com';
        like $csp, qr/api\.stripe\.com/,      'CSP allows api.stripe.com';
        like $csp, qr/frame-src[^;]*js\.stripe\.com/, 'CSP frame-src allows stripe';
        like $csp, qr/img-src[^;]*data:/,     'CSP img-src allows data URIs';
    };
}

subtest '200 response has security headers' => sub {
    $t->get_ok('/')->status_is(200);
    check_security_headers( '200 response', $t->tx );
};

subtest 'Error response has security headers' => sub {
    # The app routes unknown paths through the workflow controller, which
    # returns a 500 when the workflow is not found. Security headers must
    # be present on error responses regardless of the status code.
    $t->get_ok('/this-route-does-not-exist-at-all-12345');
    my $status = $t->tx->res->code;
    ok( $status == 404 || $status == 500, "Got error response ($status)" );
    check_security_headers( 'error response', $t->tx );
};

subtest 'Redirect response has security headers' => sub {
    # Fetch the form first so that the CSRF token is in the session
    $t->get_ok('/tenant-signup')->status_is(200);
    my $csrf_input = $t->tx->res->dom->at('input[name="csrf_token"]');
    my $token = $csrf_input ? $csrf_input->attr('value') : '';

    # POST to workflow start with a valid CSRF token - should redirect to next step
    $t->post_ok( '/tenant-signup' => form => {
        csrf_token        => $token,
        organization_name => 'Test Org',
        billing_email     => 'test@example.com',
    } )->status_is(302);
    check_security_headers( 'redirect response', $t->tx );
};

subtest 'HSTS header only present on HTTPS' => sub {
    # In test environment (HTTP), HSTS must not be set
    $t->get_ok('/')->status_is(200);
    my $hsts = $t->tx->res->headers->header('Strict-Transport-Security');
    ok !$hsts, 'HSTS not set over plain HTTP';
};
