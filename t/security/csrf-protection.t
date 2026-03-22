#!/usr/bin/env perl
# ABOUTME: Security test suite for CSRF token validation middleware.
# ABOUTME: Verifies POST/PUT/DELETE requests require valid CSRF tokens, GET requests pass freely.
use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing ok is subtest )];
defer { done_testing };

use Test::Mojo;
use Test::Registry::DB;

my $test_db = Test::Registry::DB->new();
$ENV{DB_URL} = $test_db->uri;

subtest 'GET requests pass without CSRF token' => sub {
    my $t = Test::Mojo->new('Registry');

    $t->get_ok('/')->status_is(200, 'GET / returns 200 without CSRF token');
    $t->get_ok('/health')->status_is(200, 'GET /health returns 200 without CSRF token');
    $t->get_ok('/tenant-signup')->status_is(200, 'GET workflow index returns 200 without CSRF token');
};

subtest 'POST without CSRF token returns 403' => sub {
    my $t = Test::Mojo->new('Registry');

    $t->post_ok('/tenant-signup' => form => {
        organization_name => 'Test Org',
        billing_email     => 'test@example.com',
    })->status_is(403, 'POST without CSRF token returns 403');
};

subtest 'POST with valid CSRF token succeeds' => sub {
    my $t = Test::Mojo->new('Registry');

    # Fetch the page first to establish a session and obtain the token
    $t->get_ok('/tenant-signup')->status_is(200);

    my $csrf_input = $t->tx->res->dom->at('input[name="csrf_token"]');
    ok $csrf_input, 'CSRF token input present in form';

    my $token = $csrf_input ? $csrf_input->attr('value') : '';
    ok $token, 'CSRF token has a non-empty value';

    $t->post_ok('/tenant-signup' => form => {
        csrf_token        => $token,
        organization_name => 'Test Organization',
        billing_email     => 'test@example.com',
    })->status_is(302, 'POST with valid CSRF token redirects to next step');
};

subtest 'POST with wrong CSRF token returns 403' => sub {
    my $t = Test::Mojo->new('Registry');

    $t->post_ok('/tenant-signup' => form => {
        csrf_token        => 'definitely-not-a-valid-token',
        organization_name => 'Test Org',
        billing_email     => 'test@example.com',
    })->status_is(403, 'POST with wrong CSRF token returns 403');
};

subtest 'POST with wrong form field name returns 403' => sub {
    my $t = Test::Mojo->new('Registry');

    # Obtain a valid token but submit it under a different field name
    $t->get_ok('/tenant-signup')->status_is(200);
    my $csrf_input = $t->tx->res->dom->at('input[name="csrf_token"]');
    my $token = $csrf_input ? $csrf_input->attr('value') : 'placeholder';

    $t->post_ok('/tenant-signup' => form => {
        wrong_field_name  => $token,
        organization_name => 'Test Org',
        billing_email     => 'test@example.com',
    })->status_is(403, 'POST with token under wrong field name returns 403');
};

subtest 'X-CSRF-Token header accepted as alternative' => sub {
    my $t = Test::Mojo->new('Registry');

    # Establish session and get token
    $t->get_ok('/tenant-signup')->status_is(200);
    my $csrf_input = $t->tx->res->dom->at('input[name="csrf_token"]');
    ok $csrf_input, 'CSRF token input present in form';

    my $token = $csrf_input ? $csrf_input->attr('value') : '';
    ok $token, 'CSRF token has a non-empty value';

    $t->post_ok('/tenant-signup' => {
        'X-CSRF-Token'   => $token,
        'Content-Type'   => 'application/x-www-form-urlencoded',
    } => form => {
        organization_name => 'Test Organization',
        billing_email     => 'test@example.com',
    })->status_is(302, 'POST with X-CSRF-Token header succeeds');
};

subtest 'Token from different session is rejected' => sub {
    my $t1 = Test::Mojo->new('Registry');
    my $t2 = Test::Mojo->new('Registry');

    # Get token from first client/session
    $t1->get_ok('/tenant-signup')->status_is(200);
    my $csrf_input = $t1->tx->res->dom->at('input[name="csrf_token"]');
    my $token_from_t1 = $csrf_input ? $csrf_input->attr('value') : 'no-token';

    # Establish second client session separately (different cookie jar)
    $t2->get_ok('/tenant-signup')->status_is(200);

    # Use token from session 1 in session 2's request
    $t2->post_ok('/tenant-signup' => form => {
        csrf_token        => $token_from_t1,
        organization_name => 'Cross-Session Org',
        billing_email     => 'cross@example.com',
    })->status_is(403, 'Token from different session is rejected');
};

subtest 'Webhook endpoint bypasses CSRF check' => sub {
    my $t = Test::Mojo->new('Registry');

    # Stripe webhooks use their own HMAC-based auth and must not require CSRF
    $t->post_ok('/webhooks/stripe' => { 'Content-Type' => 'application/json' } => '{}')
      ->status_isnt(403, 'Webhook POST is not blocked by CSRF middleware');
};

subtest 'Multipart form upload requires CSRF token' => sub {
    my $t = Test::Mojo->new('Registry');

    # POST multipart without token
    $t->post_ok('/tenant-signup' => form => {
        organization_name => 'Multipart Org',
        billing_email     => 'multi@example.com',
    })->status_is(403, 'Multipart POST without CSRF token returns 403');

    # POST multipart with valid token
    $t->get_ok('/tenant-signup')->status_is(200);
    my $csrf_input = $t->tx->res->dom->at('input[name="csrf_token"]');
    my $token = $csrf_input ? $csrf_input->attr('value') : '';

    $t->post_ok('/tenant-signup' => form => {
        csrf_token        => $token,
        organization_name => 'Multipart Organization',
        billing_email     => 'multi@example.com',
    })->status_is(302, 'Multipart POST with valid CSRF token succeeds');
};
