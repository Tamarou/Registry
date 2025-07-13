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

# Test marketing page renders when no tenant context
subtest 'Marketing page renders without tenant context' => sub {
    # Root redirects to marketing page
    my $tx = $t->get_ok('/')->status_is(302);
    
    # Follow redirect to marketing page
    my $location = $tx->tx->res->headers->location;
    $tx = $t->get_ok($location)->status_is(200);
    
    # Check content includes key marketing elements
    $tx->content_like(qr/After-School Program Management Made Simple/i)
      ->content_like(qr/Start Your Free Trial/i)
      ->content_like(qr/30 days free/i)
      ->content_like(qr/\$200/i)
      ->content_like(qr/per month/i)
      ->content_like(qr/tenant-signup/i); # Should link to tenant signup workflow
};

subtest 'Marketing page includes required SEO elements' => sub {
    my $tx = $t->get_ok('/marketing')->status_is(200);
    
    # Check meta tags and SEO elements
    $tx->element_exists('title')
      ->content_like(qr/Registry.*After-School Program Management/i);
};

subtest 'Marketing page includes feature descriptions' => sub {
    my $tx = $t->get_ok('/marketing')->status_is(200);
    
    # Check that key features are mentioned
    $tx->content_like(qr/Registration/i)
      ->content_like(qr/Payment Processing/i)
      ->content_like(qr/Attendance Tracking/i)
      ->content_like(qr/Family Communication/i)
      ->content_like(qr/Waitlist Management/i)
      ->content_like(qr/Staff Management/i);
};

subtest 'Marketing page includes pricing information' => sub {
    my $tx = $t->get_ok('/marketing')->status_is(200);
    
    # Check pricing details
    $tx->content_like(qr/\$200/i)
      ->content_like(qr/per month/i)
      ->content_like(qr/30.*day.*free.*trial/i)
      ->content_like(qr/No.*credit.*card.*required/i);
};

subtest 'Marketing page includes contact information' => sub {
    my $tx = $t->get_ok('/marketing')->status_is(200);
    
    # Check support contact info
    $tx->content_like(qr/support\@registry\.com/i)
      ->content_like(qr/1-800-REGISTRY/i);
};

subtest 'Marketing page CTA links to tenant signup' => sub {
    my $tx = $t->get_ok('/marketing')->status_is(200);
    
    # Check that CTA buttons link to tenant signup workflow
    $tx->element_exists('a[href*="tenant-signup"]');
};

subtest 'Marketing page is mobile responsive' => sub {
    my $tx = $t->get_ok('/marketing')->status_is(200);
    
    # Check for responsive meta tag and CSS
    $tx->content_like(qr/\@media.*max-width/s); # Check for responsive CSS
};

done_testing();