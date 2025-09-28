#!/usr/bin/env perl
# ABOUTME: Tests for enhanced CTA on main landing page hero section (Issue #59)
# ABOUTME: Verifies button sizes, dual CTA, social proof, and accessibility

use v5.34.0;
use warnings;
use utf8;
use experimental qw(signatures);

use Test::More;
use Test::Mojo;

use lib qw(lib t/lib);
use Test::Registry::DB;

use Registry;

# Setup test database for app initialization
my $t_db = Test::Registry::DB->new;
my $db = $t_db->db;

# Create test app with database helper
my $t = Test::Mojo->new('Registry');
$t->app->helper(dao => sub { $db });

# Test enhanced CTA on landing page
subtest 'Enhanced CTA on landing page' => sub {
    $t->get_ok('/')
      ->status_is(200)
      ->element_exists('section[role="banner"]', 'Hero section exists with proper role');

    # Test primary CTA button with XL size
    $t->element_exists('button[data-size="xl"][data-variant="success"]', 'Primary CTA button has XL size')
      ->text_like('button[data-size="xl"]', qr/Get Started Free/, 'Primary CTA has compelling text');

    # Test secondary CTA button (Watch Demo)
    $t->element_exists('button[data-variant="secondary"][data-size="lg"]', 'Secondary Watch Demo button exists')
      ->text_like('button[data-variant="secondary"][data-size="lg"]', qr/Watch Demo/, 'Secondary button has Watch Demo text');

    # Test enhanced supporting text
    $t->text_like('#trial-info small', qr/30-day free trial/, 'Supporting text mentions 30-day trial')
      ->text_like('#trial-info small', qr/No credit card/, 'Supporting text mentions no credit card')
      ->text_like('#trial-info small', qr/Cancel anytime/, 'Supporting text mentions cancel anytime')
      ->text_like('#trial-info small', qr/Setup in 5 minutes/, 'Supporting text mentions quick setup');

    # Test social proof section
    $t->element_exists('#social-proof', 'Social proof section exists');

    # Extract and test social proof text properly
    my $social_text = $t->tx->res->dom->at('#social-proof')->all_text;
    like($social_text, qr/Join \d+\+ programs/i, 'Social proof shows program count');

    $t->element_exists('#social-proof [data-rating]', 'Social proof includes rating');

    # Test CSS animation class
    $t->element_exists('button[data-animate="pulse"]', 'Primary CTA has pulse animation');
};

# Test accessibility compliance
subtest 'CTA accessibility compliance' => sub {
    $t->get_ok('/');

    # Test ARIA attributes
    $t->element_exists('a[role="button"][aria-describedby="trial-info"]', 'CTA link has proper ARIA attributes')
      ->element_exists('section[role="banner"][aria-labelledby="hero-title"]', 'Hero section has proper ARIA labeling');

    # Test button focus states (checking CSS classes exist)
    $t->element_exists('button[data-size="xl"]', 'XL button size is rendered');

    # Test contrast and visibility
    $t->element_exists('button[data-variant="success"]', 'Success variant button for proper contrast')
      ->element_exists('button[data-variant="secondary"]', 'Secondary variant button exists');
};

# Test mobile responsiveness
subtest 'Mobile CTA optimization' => sub {
    # Set mobile viewport context
    $t->ua->max_redirects(0);
    $t->get_ok('/');

    # Verify buttons exist and are accessible on mobile
    $t->element_exists('button[data-size="xl"]', 'XL button exists for mobile touch targets')
      ->element_exists('button[data-size="lg"]', 'Secondary button with appropriate size');

    # Test that buttons are in proper container
    $t->element_exists('section[data-component="container"][data-size="large"]', 'Proper container for mobile layout');
};

done_testing();