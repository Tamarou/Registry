#!/usr/bin/env perl
# ABOUTME: Tests for tenant team member creation UI
# ABOUTME: Ensures no duplicate buttons and working add member functionality

use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(defer try);
use Test::More import => [qw( done_testing is ok like is_deeply subtest use_ok isa_ok can_ok )];
use Test::Mojo;
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;
use Test::Registry::Fixtures;

my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db();
my $db = $dao->db;
my $t = Test::Mojo->new('Registry');

# Start tenant signup workflow
$t->get_ok('/tenant-signup')
    ->status_is(200)
    ->content_like(qr/Let's Get Started/);

# Start the workflow
$t->post_ok('/tenant-signup')
    ->status_is(302);

# Get redirect location and extract run ID
my $location = $t->tx->res->headers->location;
my ($run_id) = $location =~ m{/tenant-signup/([^/]+)/};

# Complete profile step
$t->post_ok("/tenant-signup/$run_id/profile" => form => {
    name => 'Test Organization',
    billing_email => 'billing@test.org',
    billing_phone => '555-1234',
    billing_address => '123 Test St',
    billing_city => 'Test City',
    billing_state => 'TS',
    billing_zip => '12345',
    billing_country => 'US',
})->status_is(302);

# Check we're redirected to users step
$location = $t->tx->res->headers->location;
like($location, qr{/tenant-signup/[^/]+/users}, 'Redirected to users step');

# Get the users page and check for issues
$t->get_ok("/tenant-signup/$run_id/users")
    ->status_is(200);

# Test 1: Check that there's only ONE submit/continue button
my $dom = $t->tx->res->dom;
my @submit_buttons = $dom->find('button[type="submit"]')->each;
is(scalar(@submit_buttons), 1, 'Should have exactly one submit button');

# Test 2: Check that the form has proper structure
my @forms = $dom->find('form')->each;
is(scalar(@forms), 1, 'Should have exactly one form element');

# Test 3: Verify the continue button is inside the form
my $form = $forms[0];
my @form_submit_buttons = $form->find('button[type="submit"]')->each;
is(scalar(@form_submit_buttons), 1, 'Submit button should be inside the form');

# Test 4: Check that add team member button is NOT a submit button
my @add_buttons = $dom->find('button#add-member-btn')->each;
if (@add_buttons) {
    my $add_button = $add_buttons[0];
    is($add_button->attr('type'), 'button', 'Add member button should be type="button", not submit');
}

# Test 5: Verify the form can be submitted properly
$t->post_ok("/tenant-signup/$run_id/users" => form => {
    admin_name => 'Admin User',
    admin_email => 'admin@test.org',
    admin_username => 'adminuser',
    admin_password => 'TestPass123!',
    admin_user_type => 'admin',
})->status_is(302, 'Form submission should redirect to next step');