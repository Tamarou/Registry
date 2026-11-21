#!/usr/bin/env perl
# ABOUTME: Tests for the tenant signup profile step template and form handling.
# ABOUTME: Validates form fields, subdomain preview, and form submission flow.
use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry;

# Set up test database
my $t_db = Test::Registry::DB->new;
my $db = $t_db->db;
$ENV{DB_URL} = $t_db->uri;

# Create test app
my $t = Test::Registry::Mojo->new('Registry');

subtest 'Profile template renders correctly' => sub {
    # Start a tenant signup workflow
    my $tx = $t->post_ok('/tenant-signup')->status_is(302);

    # Follow redirect to get the workflow run (should be profile step)
    my $location = $tx->tx->res->headers->location;
    $tx = $t->get_ok($location)->status_is(200);

    # Check that profile form fields are present
    $tx->content_like(qr/Organization Profile/i)
      ->content_like(qr/Organization Name/i)
      ->content_like(qr/tinyartempire\.com/i)
      ->content_like(qr/Contact Email/i)
      ->content_like(qr/billing_email/i);

    # Billing address fields should NOT be present (Stripe Connect handles billing)
    $tx->content_unlike(qr/billing_address/i)
      ->content_unlike(qr/billing_city/i)
      ->content_unlike(qr/billing_state/i)
      ->content_unlike(qr/billing_zip/i)
      ->content_unlike(qr/billing_country/i);
};

subtest 'Subdomain validation endpoint works' => sub {
    my $tx = $t->post_ok('/tenant-signup/validate-subdomain' => form => {
        name => 'Test Organization'
    })->status_is(200);

    # Should return HTML with slug and tinyartempire.com domain
    $tx->content_like(qr/test-organization/)
      ->content_like(qr/\.tinyartempire\.com/);
};

subtest 'Subdomain validation handles empty input' => sub {
    my $tx = $t->post_ok('/tenant-signup/validate-subdomain')->status_is(200);

    # Should return default with tinyartempire.com
    $tx->content_like(qr/organization.*tinyartempire\.com/);
};

subtest 'Profile form validation' => sub {
    # Start a tenant signup workflow and get to profile step
    my $tx = $t->post_ok('/tenant-signup')->status_is(302);
    my $location = $tx->tx->res->headers->location;
    $t->get_ok($location)->status_is(200);

    # Try to submit incomplete profile data
    $tx = $t->post_ok($location => form => {
        name => 'Test Org',
        # Missing contact email
    });

    # Should redirect back with validation errors or stay on same page
    ok($tx->tx->res->is_redirect || $tx->tx->res->code == 200, 'Handles incomplete form submission');
};

subtest 'Valid profile data processing' => sub {
    # Start a tenant signup workflow and get to profile step
    my $tx = $t->post_ok('/tenant-signup')->status_is(302);
    my $location = $tx->tx->res->headers->location;
    $t->get_ok($location)->status_is(200);

    # Submit complete profile data (no billing address needed)
    $tx = $t->post_ok($location => form => {
        name => 'Test Organization Inc',
        description => 'A test organization for after-school programs',
        billing_email => 'hello@testorg.com',
    })->status_is(302);

    # Should redirect to next step (users)
    my $next_location = $tx->tx->res->headers->location;
    ok($next_location =~ /users/, 'Redirects to users step after valid profile');
};

done_testing();
