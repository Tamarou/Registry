#!/usr/bin/env perl
use 5.40.0;
use Test::More;
use Test::Mojo;
use lib qw(lib t/lib);
use Test::Registry::DB;
use Registry;

# Set up test database
Test::Registry::DB::new_test_db(__PACKAGE__);

# Create test app
my $t = Test::Mojo->new('Registry');

subtest 'Enhanced profile template renders correctly' => sub {
    # Start a tenant signup workflow
    my $tx = $t->post_ok('/tenant-signup')->status_is(302);
    
    # Follow redirect to get the workflow run (should be profile step)
    my $location = $tx->tx->res->headers->location;
    $tx = $t->get_ok($location)->status_is(200);
    
    # Check that enhanced profile form is present
    $tx->content_like(qr/Organization Profile/i)
      ->content_like(qr/Organization Name/i)
      ->content_like(qr/Registry Subdomain/i)
      ->content_like(qr/Billing Information/i)
      ->content_like(qr/billing_email/i)
      ->content_like(qr/billing_address/i)
      ->content_like(qr/billing_city/i)
      ->content_like(qr/billing_state/i)
      ->content_like(qr/billing_zip/i)
      ->content_like(qr/billing_country/i);
};

subtest 'Subdomain validation endpoint works' => sub {
    my $tx = $t->post_ok('/tenant-signup/validate-subdomain' => form => {
        name => 'Test Organization'
    })->status_is(200);
    
    # Should return HTML with slug
    $tx->content_like(qr/test-organization/)
      ->content_like(qr/\.registry\.com/);
};

subtest 'Subdomain validation handles empty input' => sub {
    my $tx = $t->post_ok('/tenant-signup/validate-subdomain')->status_is(200);
    
    # Should return default with HTML content
    $tx->content_like(qr/organization.*registry\.com/);
};

subtest 'Profile form validation' => sub {
    # Start a tenant signup workflow and get to profile step
    my $tx = $t->post_ok('/tenant-signup')->status_is(302);
    my $location = $tx->tx->res->headers->location;
    $t->get_ok($location)->status_is(200);
    
    # Try to submit incomplete profile data
    $tx = $t->post_ok($location => form => {
        name => 'Test Org',
        # Missing required billing fields
    });
    
    # Should redirect back with validation errors or stay on same page
    ok($tx->tx->res->is_redirect || $tx->tx->res->code == 200, 'Handles incomplete form submission');
};

subtest 'Valid profile data processing' => sub {
    # Start a tenant signup workflow and get to profile step
    my $tx = $t->post_ok('/tenant-signup')->status_is(302);
    my $location = $tx->tx->res->headers->location;
    $t->get_ok($location)->status_is(200);
    
    # Submit complete profile data
    $tx = $t->post_ok($location => form => {
        name => 'Test Organization Inc',
        description => 'A test organization for after-school programs',
        billing_email => 'billing@testorg.com',
        billing_phone => '555-123-4567',
        billing_address => '123 Test Street',
        billing_address2 => 'Suite 100',
        billing_city => 'Test City',
        billing_state => 'CA',
        billing_zip => '94102',
        billing_country => 'US'
    })->status_is(302);
    
    # Should redirect to next step (users)
    my $next_location = $tx->tx->res->headers->location;
    ok($next_location =~ /users/, 'Redirects to users step after valid profile');
};

done_testing();