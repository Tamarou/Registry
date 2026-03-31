#!/usr/bin/env perl
# ABOUTME: Integration test for the full magic link two-phase verify+consume flow.
# ABOUTME: Covers verify-only GET, same-device complete POST, session establishment, and reuse prevention.
use 5.42.0;
use warnings;
use utf8;

use Test::More;

use lib qw(lib t/lib);
use Test::Registry::Mojo;
use Test::Registry::DB;

use Registry::DAO::User;
use Registry::DAO::MagicLinkToken;

my $tdb = Test::Registry::DB->new;
my $dao = $tdb->db;
my $db  = $dao->db;

my $user = Registry::DAO::User->create($db, {
    username  => 'integration_auth_user',
    email     => 'integration@example.com',
    name      => 'Integration Tester',
    user_type => 'admin',
    password  => 'test_password',
});

subtest 'Full magic link login flow (same-device: verify then complete)' => sub {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper(dao => sub { $dao });

    # Generate a token (simulating what request_magic_link does)
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'login',
    });

    ok($token_obj, 'Token generated successfully');
    ok($plaintext,  'Plaintext token returned');

    # Phase 1: verify the magic link (renders confirmation page, no session yet)
    $t->get_ok("/auth/magic/$plaintext")
      ->status_is(200, 'Magic link verify renders confirmation page');

    # Phase 2: complete via same-device POST (establishes session, redirects)
    $t->post_ok("/auth/magic/$plaintext/complete")
      ->status_is(302, 'Magic link complete redirects after consuming token');

    # Session should now be established - access a protected route
    # The admin dashboard requires admin role, and the user is admin type
    $t->get_ok('/admin/dashboard')
      ->status_isnt(401, 'Can access protected route after magic link login')
      ->status_isnt(302, 'Not redirected to login after magic link login');

    # Get CSRF token by fetching an HTML page that contains one
    $t->get_ok('/auth/login');
    my $csrf_input = $t->tx->res->dom->at('input[name="csrf_token"]');
    my $csrf_token = $csrf_input ? $csrf_input->attr('value') : '';

    # Logout (requires CSRF token since it's a POST)
    $t->post_ok('/auth/logout' => form => { csrf_token => $csrf_token })
      ->status_is(302, 'Logout redirects');

    # Should now be rejected from protected routes
    my $status = $t->get_ok('/admin/dashboard')->tx->res->code;
    ok($status == 302 || $status == 401 || $status == 403,
        "Redirected or denied after logout (got $status)");
};

subtest 'Invalid magic link token returns error' => sub {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper(dao => sub { $dao });

    $t->get_ok('/auth/magic/thisisnotavalidtoken')
      ->status_isnt(302, 'Invalid token does not redirect to success');
};

subtest 'Consumed magic link shows already-signed-in on second use' => sub {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper(dao => sub { $dao });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'login',
    });

    # First use: verify then complete
    $t->get_ok("/auth/magic/$plaintext")
      ->status_is(200, 'First GET verify renders confirmation page');
    $t->post_ok("/auth/magic/$plaintext/complete")
      ->status_is(302, 'First POST complete establishes session');

    # Second GET of the same token shows already-signed-in page (not 302)
    $t->get_ok("/auth/magic/$plaintext")
      ->status_is(200, 'Second GET of same token renders page, not redirect')
      ->content_like(qr/already.*signed.?in/i, 'Shows already-signed-in message');
};

done_testing();
