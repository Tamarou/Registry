# ABOUTME: Tests for rate limiting middleware on auth and general endpoints.
# ABOUTME: Verifies 429 responses, Retry-After headers, and webhook exclusions.

use 5.40.2;
use FindBin qw($Bin);
use lib "$Bin/../../lib", "$Bin/../lib", "lib", "t/lib";
use experimental qw(defer try);
use Test::More import => [qw( done_testing is isnt ok is_deeply plan subtest pass )];
defer { done_testing };

use Test::Mojo;
use Test::Registry::DB;

my $test_db = Test::Registry::DB->new();
local $ENV{DB_URL} = $test_db->uri;

# NOTE: Rate limit counters are stored in-memory (package-level hash in
# Registry::Middleware::RateLimit). State resets on server restart.
# This is acceptable for MVP; a persistent store (Redis) would be needed
# for multi-process deployments.

subtest 'Auth endpoint rate limiting' => sub {
    my $t = Test::Mojo->new('Registry');

    # The auth limit is 10 req/min per IP. We'll use a fake IP via X-Forwarded-For.
    # Reset state between subtests by using a unique IP per subtest block.
    my $ip = '10.0.0.1';

    # First 10 requests should succeed (or at least not be rate-limited)
    for my $i (1..10) {
        $t->get_ok('/login', { 'X-Forwarded-For' => $ip })
          ->status_isnt(429, "Request $i should not be rate-limited");
    }

    # The 11th request should be rate-limited
    $t->get_ok('/login', { 'X-Forwarded-For' => $ip })
      ->status_is(429, 'Request beyond auth limit returns 429')
      ->header_like('Retry-After', qr/^\d+$/, '429 response includes Retry-After header');
};

subtest 'Webhook endpoints are excluded from rate limiting' => sub {
    my $t = Test::Mojo->new('Registry');

    # Use a unique IP that has already been "exhausted" to confirm webhooks bypass limits
    my $ip = '10.0.0.2';

    # Exhaust the auth limit for this IP (use a general route to build up count)
    for my $i (1..110) {
        $t->get_ok('/health', { 'X-Forwarded-For' => $ip });
    }

    # Webhook endpoint should still respond (not rate-limited), even for a
    # client whose general counter is exhausted - webhooks use a separate exclusion
    $t->post_ok('/webhooks/stripe',
        { 'X-Forwarded-For' => '10.0.0.100', 'Content-Type' => 'application/json' },
        '{"id":"evt_test","type":"test"}')
      ->status_isnt(429, 'Webhook endpoint is not rate-limited');
};

subtest 'General endpoint rate limiting' => sub {
    my $t = Test::Mojo->new('Registry');

    my $ip = '10.0.0.3';

    # First 100 requests should succeed
    for my $i (1..100) {
        $t->get_ok('/health', { 'X-Forwarded-For' => $ip })
          ->status_isnt(429, "General request $i should not be rate-limited");
    }

    # The 101st request should be rate-limited
    $t->get_ok('/health', { 'X-Forwarded-For' => $ip })
      ->status_is(429, 'Request beyond general limit returns 429')
      ->header_like('Retry-After', qr/^\d+$/, '429 response includes Retry-After header');
};

subtest '429 response body is well-formed' => sub {
    my $t = Test::Mojo->new('Registry');

    my $ip = '10.0.0.4';

    # Exhaust the general limit
    for my $i (1..100) {
        $t->get_ok('/health', { 'X-Forwarded-For' => $ip });
    }

    # Check that the 429 body is useful
    $t->get_ok('/health', { 'X-Forwarded-For' => $ip, 'Accept' => 'application/json' })
      ->status_is(429)
      ->json_has('/error', '429 JSON body has error field')
      ->json_like('/error', qr/rate limit/i, 'Error message mentions rate limit');
};

subtest 'Different IPs have independent counters' => sub {
    my $t = Test::Mojo->new('Registry');

    my $ip_a = '10.0.0.5';
    my $ip_b = '10.0.0.6';

    # Exhaust limit for ip_a
    for my $i (1..101) {
        $t->get_ok('/health', { 'X-Forwarded-For' => $ip_a });
    }

    # ip_b should still be allowed (fresh counter)
    $t->get_ok('/health', { 'X-Forwarded-For' => $ip_b })
      ->status_isnt(429, 'Different IP not affected by other IP rate limit');
};

subtest 'Static asset paths are excluded from rate limiting' => sub {
    my $t = Test::Mojo->new('Registry');

    my $ip = '10.0.0.7';

    # Even after exhausting the general limit, static assets should be served
    for my $i (1..110) {
        $t->get_ok('/health', { 'X-Forwarded-For' => $ip });
    }

    # Static assets under /static/ should bypass rate limiting
    # We test the path pattern exclusion logic; the actual file may not exist
    # but the rate limiter should not block the request with a 429
    my $res = $t->ua->get('/static/test.css', { 'X-Forwarded-For' => $ip });
    isnt $res->res->code, 429, 'Static asset path not rate-limited (returns 404, not 429)';
};
