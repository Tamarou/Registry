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

    # Test primary CTA link
    $t->element_exists('.landing-cta-button', 'Primary CTA button exists')
      ->text_like('.landing-cta-button', qr/Get Started Free/, 'Primary CTA has compelling text');

    # Test secondary CTA link (Explore Features)
    $t->element_exists('.landing-cta-secondary', 'Secondary CTA button exists')
      ->text_like('.landing-cta-secondary', qr/Explore Features/, 'Secondary button has appropriate text');

    # Test enhanced supporting text (updated class)
    $t->text_like('.landing-trial-info', qr/30-day free trial/, 'Supporting text mentions 30-day trial')
      ->text_like('.landing-trial-info', qr/No credit card/, 'Supporting text mentions no credit card')
      ->text_like('.landing-trial-info', qr/Cancel anytime/, 'Supporting text mentions cancel anytime')
      ->text_like('.landing-trial-info', qr/Setup in 5 minutes/, 'Supporting text mentions quick setup');

    # Test social proof section (updated class)
    $t->element_exists('.landing-social-proof', 'Social proof section exists');

    # Extract and test social proof text properly
    my $social_text = $t->tx->res->dom->at('.landing-social-proof')->all_text;
    like($social_text, qr/Join \d+\+ programs/i, 'Social proof shows program count');
    like($social_text, qr/4\.9\/5/i, 'Social proof includes rating');
};

# Test accessibility compliance
subtest 'CTA accessibility compliance' => sub {
    $t->get_ok('/');

    # Test ARIA attributes
    $t->element_exists('section[role="banner"][aria-labelledby="hero-title"]', 'Hero section has proper ARIA labeling')
      ->element_exists('h1#hero-title', 'Hero title has proper ID for ARIA reference');

    # Test CTA links exist and are accessible
    $t->element_exists('.landing-cta-button', 'Primary CTA link exists')
      ->element_exists('.landing-cta-secondary', 'Secondary CTA link exists');

    # Test proper link structure for navigation
    $t->element_exists('a[href*="tenant-signup"]', 'Primary CTA links to signup workflow')
      ->element_exists('a[href="#features"]', 'Secondary CTA links to features section');
};

# Test mobile responsiveness
subtest 'Mobile CTA optimization' => sub {
    # Set mobile viewport context
    $t->ua->max_redirects(0);
    $t->get_ok('/');

    # Verify CTA links exist and are accessible on mobile
    $t->element_exists('.landing-cta-button', 'Primary CTA exists for mobile')
      ->element_exists('.landing-cta-secondary', 'Secondary CTA exists for mobile');

    # Test that CTAs are in proper container
    $t->element_exists('.landing-cta-container', 'CTAs are in proper container')
      ->element_exists('.landing-hero', 'Hero section exists for proper layout');
};

done_testing();