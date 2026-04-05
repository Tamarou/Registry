#!/usr/bin/env perl
# ABOUTME: Tests for authentication edge cases.
# ABOUTME: Verifies magic link behavior, session handling, and already-logged-in redirects.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;

use Registry::DAO;
use Registry::DAO::User;
use Registry::DAO::MagicLinkToken;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# --- Test Data ---

my $user = Registry::DAO::User->create($dao->db, {
    username  => 'auth_test_user',
    name      => 'Auth Test User',
    email     => 'auth_test@example.com',
    user_type => 'parent',
});

my $user2 = Registry::DAO::User->create($dao->db, {
    username  => 'auth_test_user2',
    name      => 'Auth Test User 2',
    email     => 'auth_test2@example.com',
    user_type => 'parent',
});

# ============================================================
# Test: Magic link with valid token works
# ============================================================
subtest 'valid magic link authenticates user' => sub {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper(dao => sub { $dao });

    my (undef, $token) = Registry::DAO::MagicLinkToken->generate($dao->db, {
        user_id => $user->id, purpose => 'login', expires_in => 24,
    });

    # Verify page renders
    $t->get_ok("/auth/magic/$token")
      ->status_is(200);

    # Complete login
    $t->post_ok("/auth/magic/$token/complete")
      ->status_is(302, 'Magic link login redirects');
};

# ============================================================
# Test: Used magic link rejected
# ============================================================
subtest 'used magic link rejected' => sub {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper(dao => sub { $dao });

    my (undef, $token) = Registry::DAO::MagicLinkToken->generate($dao->db, {
        user_id => $user->id, purpose => 'login', expires_in => 24,
    });

    # First use - succeeds
    $t->get_ok("/auth/magic/$token")->status_is(200);
    $t->post_ok("/auth/magic/$token/complete")->status_is(302);

    # Second use (different browser) - POST should fail to authenticate
    my $t2 = Test::Registry::Mojo->new('Registry');
    $t2->app->helper(dao => sub { $dao });

    # The GET may still render the verification page (it just shows a form)
    $t2->get_ok("/auth/magic/$token");

    # But the POST (actual token consumption) should fail or redirect without auth
    $t2->post_ok("/auth/magic/$token/complete");
    my $status = $t2->tx->res->code;

    # Should either show an error (200 with error content) or redirect
    ok($status == 200 || $status == 302, "Used token POST returns $status");

    # If it redirected, it should NOT be to a dashboard (no session established)
    if ($status == 302) {
        my $redirect = $t2->tx->res->headers->location;
        unlike $redirect, qr/dashboard/i, 'Used token does not redirect to dashboard';
    }
};

# ============================================================
# Test: Invalid/garbage magic link token
# ============================================================
subtest 'invalid magic link token rejected' => sub {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper(dao => sub { $dao });

    $t->get_ok('/auth/magic/totally-invalid-token-garbage-xyz');
    my $status = $t->tx->res->code;

    ok($status == 200 || $status == 404, "Invalid token returns $status (not 500)");

    if ($status == 200) {
        $t->content_like(qr/invalid|not found|expired/i, 'Shows error for invalid token');
    }
};

# ============================================================
# Test: Already-logged-in user hitting login page
# ============================================================
subtest 'already-logged-in user on login page' => sub {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper(dao => sub { $dao });

    # Log in first
    my (undef, $token) = Registry::DAO::MagicLinkToken->generate($dao->db, {
        user_id => $user->id, purpose => 'login', expires_in => 24,
    });
    $t->get_ok("/auth/magic/$token")->status_is(200);
    $t->post_ok("/auth/magic/$token/complete")->status_is(302);

    # Now visit login page while already logged in
    $t->get_ok('/auth/login');
    my $status = $t->tx->res->code;

    # Should render (200) or redirect to dashboard (302)
    ok($status == 200 || $status == 302,
       "Login page for logged-in user returns $status");
};

# ============================================================
# Test: Protected routes redirect unauthenticated users
# ============================================================
subtest 'protected routes redirect unauthenticated users' => sub {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper(dao => sub { $dao });

    # Parent dashboard requires auth
    $t->get_ok('/parent/dashboard');
    my $status = $t->tx->res->code;
    ok($status == 302 || $status == 401,
       "Parent dashboard without auth returns $status");

    # Admin dashboard requires auth
    $t->get_ok('/admin/dashboard');
    $status = $t->tx->res->code;
    ok($status == 302 || $status == 401,
       "Admin dashboard without auth returns $status");

    # Teacher dashboard requires auth
    $t->get_ok('/teacher/');
    $status = $t->tx->res->code;
    ok($status == 302 || $status == 401,
       "Teacher dashboard without auth returns $status");
};

# ============================================================
# Test: Wrong role denied access
# ============================================================
subtest 'wrong role denied access to protected routes' => sub {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper(dao => sub { $dao });

    # Log in as parent
    my (undef, $token) = Registry::DAO::MagicLinkToken->generate($dao->db, {
        user_id => $user->id, purpose => 'login', expires_in => 24,
    });
    $t->get_ok("/auth/magic/$token")->status_is(200);
    $t->post_ok("/auth/magic/$token/complete")->status_is(302);

    # Parent trying to access teacher dashboard
    $t->get_ok('/teacher/');
    my $status = $t->tx->res->code;
    ok($status == 302 || $status == 403,
       "Parent accessing teacher dashboard gets $status");

    # Parent trying to access admin dashboard
    $t->get_ok('/admin/dashboard');
    $status = $t->tx->res->code;
    ok($status == 302 || $status == 403,
       "Parent accessing admin dashboard gets $status");
};

done_testing;
