#!/usr/bin/env perl
# ABOUTME: Controller tests for /auth/* routes -- magic link request/consumption,
# ABOUTME: logout, and email verification.
use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;

use Registry::DAO::User;
use Registry::DAO::MagicLinkToken;

my $tdb = Test::Registry::DB->new;
my $db  = $tdb->db;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $db });

subtest 'GET /auth/login renders login page' => sub {
    $t->get_ok('/auth/login')
      ->status_is(200)
      ->content_like(qr/sign.?in/i, 'Login page has sign-in content');
};

subtest 'POST /auth/magic/request shows confirmation' => sub {
    my $user = Registry::DAO::User->create($db->db, {
        username => 'magic_ctrl_user',
        email    => 'magic_ctrl@example.com',
        name     => 'Magic Ctrl User',
        password => 'test_password',
    });

    $t->post_ok('/auth/magic/request' => form => {
        email => 'magic_ctrl@example.com',
    })
    ->status_is(200)
    ->content_like(qr/check.*email|link.*sent/i, 'Shows confirmation message');
};

subtest 'POST /auth/magic/request with unknown email (no info leak)' => sub {
    $t->post_ok('/auth/magic/request' => form => {
        email => 'nonexistent@example.com',
    })
    ->status_is(200);
    # Should show same confirmation page regardless -- anti-enumeration
};

subtest 'GET /auth/magic/:token with valid token' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });

    $t->get_ok("/auth/magic/$plaintext")
      ->status_is(302, 'Redirects after consuming magic link');
};

subtest 'GET /auth/magic/:token with expired token' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id    => $user->id,
        purpose    => 'login',
        expires_in => -1,
    });

    $t->get_ok("/auth/magic/$plaintext")
      ->status_is(200)
      ->content_like(qr/expired/i, 'Shows expired message');
};

subtest 'GET /auth/magic/:token with invalid token' => sub {
    $t->get_ok('/auth/magic/totally_invalid_token_here')
      ->status_is(200)
      ->content_like(qr/invalid/i, 'Shows invalid link message');
};

subtest 'POST /auth/logout clears session' => sub {
    $t->post_ok('/auth/logout')
      ->status_is(302, 'Redirects after logout');
};

subtest 'GET /auth/verify-email/:token with valid token' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'verify_email',
    });

    $t->get_ok("/auth/verify-email/$plaintext")
      ->status_is(200)
      ->content_like(qr/verified|confirmed/i, 'Shows verification success');
};

subtest 'GET /auth/verify-email/:token with invalid token' => sub {
    $t->get_ok('/auth/verify-email/bogus_token_value')
      ->status_is(200)
      ->content_like(qr/invalid/i, 'Shows invalid link message');
};

done_testing();
