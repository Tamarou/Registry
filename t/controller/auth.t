#!/usr/bin/env perl
# ABOUTME: Controller tests for /auth/* routes -- magic link request/consumption,
# ABOUTME: logout, and email verification.

# Set test email transport before any modules that use Email::Sender are loaded
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Email::Sender::Simple;

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

subtest 'GET /auth/magic/:token with valid token renders confirmation page' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });

    $t->get_ok("/auth/magic/$plaintext")
      ->status_is(200, 'Renders confirmation page (does not redirect)')
      ->content_like(qr/sign.?in/i, 'Confirmation page has sign-in content')
      ->content_like(qr/name="csrf_token"/, 'Confirmation page has CSRF token field');
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

subtest 'POST /auth/magic/request sends magic link email to known user' => sub {
    my $transport = Email::Sender::Simple->default_transport;
    $transport->clear_deliveries;

    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });
    ok($user, 'Test user exists');

    $t->post_ok('/auth/magic/request' => form => {
        email => 'magic_ctrl@example.com',
    })
    ->status_is(200);

    my @deliveries = $transport->deliveries;
    is(scalar @deliveries, 1, 'One email was sent');

    my $delivery = $deliveries[0];
    my $envelope = $delivery->{envelope};
    is($envelope->{to}[0], 'magic_ctrl@example.com', 'Email sent to the correct address');

    my $email = $delivery->{email};
    like($email->get_header('Subject'), qr/sign.?in/i, 'Subject mentions sign in');
    like($email->as_string, qr{/auth/magic/}, 'Email body contains magic link URL');
};

subtest 'POST /auth/magic/request does not send email for unknown address' => sub {
    my $transport = Email::Sender::Simple->default_transport;
    $transport->clear_deliveries;

    $t->post_ok('/auth/magic/request' => form => {
        email => 'nobody@example.com',
    })
    ->status_is(200);

    my @deliveries = $transport->deliveries;
    is(scalar @deliveries, 0, 'No email sent for unknown address');
};

subtest 'GET /auth/magic/:token with consumed token shows already-signed-in' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });
    my $verified = $token_obj->verify($db->db);
    $verified->consume($db->db);

    $t->get_ok("/auth/magic/$plaintext")
      ->status_is(200)
      ->content_like(qr/already.*signed.?in/i, 'Shows already-signed-in message');
};

subtest 'POST /auth/magic/:token/complete establishes session' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });
    $token_obj->verify($db->db);

    $t->post_ok("/auth/magic/$plaintext/complete")
      ->status_is(302, 'Redirects after consuming');
};

subtest 'POST /auth/magic/:token/complete without prior verify fails' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });

    $t->post_ok("/auth/magic/$plaintext/complete")
      ->status_is(200)
      ->content_like(qr/invalid|expired/i, 'Shows error for unverified token');
};

subtest 'POST /auth/magic/:token/complete on already-consumed token shows already-signed-in' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });
    my $verified = $token_obj->verify($db->db);
    $verified->consume($db->db);

    $t->post_ok("/auth/magic/$plaintext/complete")
      ->status_is(200)
      ->content_like(qr/already.*signed.?in/i, 'Shows already-signed-in gracefully');
};

subtest 'GET /auth/magic/poll/:hash returns pending for fresh token' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });

    $t->get_ok("/auth/magic/poll/" . $token_obj->token_hash)
      ->status_is(200)
      ->json_is('/status', 'pending');
};

subtest 'GET /auth/magic/poll/:hash returns verified after verify()' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });
    $token_obj->verify($db->db);

    $t->get_ok("/auth/magic/poll/" . $token_obj->token_hash)
      ->status_is(200)
      ->json_is('/status', 'verified');
};

subtest 'GET /auth/magic/poll/:hash returns consumed after consume()' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });
    my $verified = $token_obj->verify($db->db);
    $verified->consume($db->db);

    $t->get_ok("/auth/magic/poll/" . $token_obj->token_hash)
      ->status_is(200)
      ->json_is('/status', 'consumed');
};

subtest 'GET /auth/magic/poll/:hash returns not_found for unknown hash' => sub {
    $t->get_ok("/auth/magic/poll/thisisnotarealhashvalue")
      ->status_is(200)
      ->json_is('/status', 'not_found');
};

subtest 'GET /auth/magic/poll/:hash returns not_found for expired token' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id    => $user->id,
        purpose    => 'login',
        expires_in => -1,
    });

    $t->get_ok("/auth/magic/poll/" . $token_obj->token_hash)
      ->status_is(200)
      ->json_is('/status', 'not_found', 'Expired token reports not_found to avoid leaking existence');
};

subtest 'POST /auth/magic/poll/:hash/complete establishes session after verify' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });
    $token_obj->verify($db->db);

    $t->post_ok("/auth/magic/poll/" . $token_obj->token_hash . "/complete")
      ->status_is(302, 'Redirects after consuming via hash');
};

subtest 'POST /auth/magic/poll/:hash/complete on unverified token shows error' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });

    $t->post_ok("/auth/magic/poll/" . $token_obj->token_hash . "/complete")
      ->status_is(200)
      ->content_like(qr/Please click the magic link/i, 'Shows not-yet-verified message, not 500');
};

subtest 'POST /auth/magic/poll/:hash/complete on already-consumed returns ok JSON' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });
    my $verified = $token_obj->verify($db->db);
    $verified->consume($db->db);

    $t->post_ok("/auth/magic/poll/" . $token_obj->token_hash . "/complete")
      ->status_is(200)
      ->json_is('/ok', 1, 'Returns ok:true gracefully');
};

subtest 'magic-link-sent page has CSRF token field' => sub {
    # POST to /auth/magic/request renders magic-link-sent; verify CSRF injected by after_render hook
    $t->post_ok('/auth/magic/request' => form => {
        email => 'magic_ctrl@example.com',
    })
    ->status_is(200)
    ->content_like(qr/name="csrf_token"/, 'magic-link-sent page includes CSRF token field');
};

subtest 'magic-link-confirm page has CSRF token field' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });

    $t->get_ok("/auth/magic/$plaintext")
      ->status_is(200)
      ->content_like(qr/name="csrf_token"/, 'magic-link-confirm page includes CSRF token field');
};

done_testing();
