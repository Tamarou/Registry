#!/usr/bin/env perl
# ABOUTME: Controller test for the invitation landing page -- consuming an invite
# ABOUTME: magic link must land on a passkey registration page that actually renders.
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
$t->app->helper( dao => sub { $db } );

subtest 'unauthenticated GET /auth/register-passkey does not render the page' => sub {
    $t->get_ok('/auth/register-passkey')
      ->status_is( 302, 'Anonymous visitor is redirected, not shown the page' )
      ->header_like( Location => qr{/auth/login}, 'Redirected to login' )
      ->content_unlike( qr/register-passkey-btn/,
        'Passkey registration control is not served to anonymous visitors' );
};

subtest 'invite magic link lands on a passkey page that renders' => sub {
    my $user = Registry::DAO::User->create( $db->db, {
        username  => 'invited_team_member',
        email     => 'invited@example.com',
        name      => 'Invited Team Member',
        user_type => 'staff',
        password  => 'test_password',
    } );

    my ( $token, $plaintext ) = Registry::DAO::MagicLinkToken->generate( $db->db, {
        user_id    => $user->id,
        purpose    => 'invite',
        expires_in => 168,
    } );

    # The link in the invitation email
    $t->get_ok("/auth/magic/$plaintext")
      ->status_is( 200, 'Invite link renders the confirmation page' );

    # Confirming the sign-in consumes the token and sends the invitee onward
    $t->post_ok("/auth/magic/$plaintext/complete")
      ->status_is( 302, 'Consuming an invite token redirects' )
      ->header_is( Location => '/auth/register-passkey',
        'Invitee is sent to passkey registration' );

    # Following that redirect must reach a real page, not a 404
    $t->get_ok('/auth/register-passkey')
      ->status_is( 200, 'Passkey registration page renders for the invitee' )
      ->content_like( qr/id="register-passkey-btn"/,
        'Page contains the passkey registration control' )
      ->content_like( qr/Register a Passkey/,
        'Page shows the passkey registration heading' );
};

done_testing();
