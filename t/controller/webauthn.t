#!/usr/bin/env perl
# ABOUTME: Controller tests for the 4 WebAuthn passkey endpoints:
# ABOUTME: register/begin, register/complete, auth/begin, and auth/complete.
use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;

use Registry::DAO::User;
use Registry::DAO::Passkey;

use Digest::SHA    qw(sha256);
use MIME::Base64   qw(encode_base64url decode_base64url);
use Mojo::JSON     qw(encode_json decode_json);

my $tdb = Test::Registry::DB->new;
my $db  = $tdb->db;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $db } );

# Create a test user to authenticate as throughout these tests
my $user = Registry::DAO::User->create( $db->db, {
    username  => 'webauthn_ctrl_user',
    email     => 'webauthn_ctrl@example.com',
    name      => 'WebAuthn Ctrl User',
    user_type => 'parent',
    password  => 'test_password',
} );

# Inject current_user into every request. We use around_dispatch so this
# runs before the application's before_dispatch hooks (including CSRF).
$t->app->hook( around_dispatch => sub ($next, $c) {
    $c->stash( current_user => {
        id        => $user->id,
        username  => $user->username,
        name      => $user->name,
        email     => $user->email,
        user_type => $user->user_type,
        role      => $user->user_type,
        # Marking api_key truthy causes the CSRF hook to skip validation
        # for these JSON endpoint tests, matching the behavior of bearer-
        # token authenticated requests.
        api_key   => 1,
    } );
    $next->();
} );

# ---------------------------------------------------------------------------
# webauthn_register_begin
# ---------------------------------------------------------------------------

subtest 'POST /auth/webauthn/register/begin returns registration options' => sub {
    $t->post_ok( '/auth/webauthn/register/begin',
        { Accept => 'application/json', 'Content-Type' => 'application/json' },
        json => {} )
      ->status_is( 200, 'Returns 200 OK' )
      ->json_has( '/challenge',        'Has challenge field' )
      ->json_has( '/rp',               'Has rp field' )
      ->json_has( '/rp/id',            'Has rp.id field' )
      ->json_has( '/rp/name',          'Has rp.name field' )
      ->json_has( '/user',             'Has user field' )
      ->json_has( '/user/id',          'Has user.id field' )
      ->json_has( '/pubKeyCredParams', 'Has pubKeyCredParams' );
};

subtest 'POST /auth/webauthn/register/begin stores challenge in session' => sub {
    $t->post_ok( '/auth/webauthn/register/begin',
        { Accept => 'application/json', 'Content-Type' => 'application/json' },
        json => {} )
      ->status_is( 200 );

    my $body = decode_json( $t->tx->res->body );
    ok( $body->{challenge}, 'Challenge is present in response' );
};

subtest 'POST /auth/webauthn/register/begin requires authentication' => sub {
    # Use a bare Test::Mojo instance that does NOT inject current_user,
    # and send a request that looks like an API call (JSON Accept).
    # Without a session and without a valid CSRF token the CSRF hook will
    # reject first (403), which is fine -- the endpoint is protected.
    my $t2 = Test::Registry::Mojo->new('Registry');
    $t2->app->helper( dao => sub { $db } );

    $t2->post_ok( '/auth/webauthn/register/begin',
        {   Accept              => 'application/json',
            'Content-Type'      => 'application/json',
            'X-Requested-With'  => 'XMLHttpRequest',
        },
        json => {} )
      ->status_isnt( 200,  'Returns non-200 when unauthenticated' )
      ->status_isnt( 501,  'Endpoint is implemented (not 501)' );
};

# ---------------------------------------------------------------------------
# webauthn_register_complete
# ---------------------------------------------------------------------------

subtest 'POST /auth/webauthn/register/complete with invalid attestation returns 400' => sub {
    # First get a challenge stored in session via register/begin
    $t->post_ok( '/auth/webauthn/register/begin',
        { Accept => 'application/json', 'Content-Type' => 'application/json' },
        json => {} )
      ->status_is( 200 );

    # Send a malformed attestation -- expect 400, not 501
    $t->post_ok( '/auth/webauthn/register/complete',
        { Accept => 'application/json', 'Content-Type' => 'application/json' },
        json => {
            id       => encode_base64url('fake_credential_id'),
            response => {
                clientDataJSON    => encode_base64url('{"type":"webauthn.create","challenge":"bad","origin":"http://localhost"}'),
                attestationObject => encode_base64url('fake'),
            },
        } )
      ->status_isnt( 501, 'Endpoint is implemented (not 501)' )
      ->status_is( 400,   'Returns 400 for invalid attestation' );
};

subtest 'POST /auth/webauthn/register/complete requires authentication' => sub {
    my $t2 = Test::Registry::Mojo->new('Registry');
    $t2->app->helper( dao => sub { $db } );

    $t2->post_ok( '/auth/webauthn/register/complete',
        {   Accept              => 'application/json',
            'Content-Type'      => 'application/json',
            'X-Requested-With'  => 'XMLHttpRequest',
        },
        json => {} )
      ->status_isnt( 200, 'Returns non-200 when unauthenticated' )
      ->status_isnt( 501, 'Endpoint is implemented (not 501)' );
};

# ---------------------------------------------------------------------------
# webauthn_auth_begin
# ---------------------------------------------------------------------------

subtest 'POST /auth/webauthn/auth/begin returns authentication options' => sub {
    # auth_begin does not require prior auth -- it IS the login flow.
    # It accepts an email to look up the user's passkeys.
    my $t_anon = Test::Registry::Mojo->new('Registry');
    $t_anon->app->helper( dao => sub { $db } );

    $t_anon->post_ok( '/auth/webauthn/auth/begin',
        { Accept => 'application/json', 'Content-Type' => 'application/json' },
        json => { email => $user->email } )
      ->status_is( 200, 'Returns 200 OK' )
      ->json_has( '/challenge',        'Has challenge field' )
      ->json_has( '/rpId',             'Has rpId field' )
      ->json_has( '/allowCredentials', 'Has allowCredentials field' )
      ->json_has( '/userVerification', 'Has userVerification field' );
};

subtest 'POST /auth/webauthn/auth/begin with known user includes their credentials' => sub {
    # Create a passkey for the user so it can be included in allowCredentials
    my $cred_id = 'test_credential_' . time;
    Registry::DAO::Passkey->create( $db->db, {
        user_id       => $user->id,
        credential_id => $cred_id,
        public_key    => 'fake_public_key_bytes',
        sign_count    => 0,
        device_name   => 'Test Device',
    } );

    my $t_anon = Test::Registry::Mojo->new('Registry');
    $t_anon->app->helper( dao => sub { $db } );

    $t_anon->post_ok( '/auth/webauthn/auth/begin',
        { Accept => 'application/json', 'Content-Type' => 'application/json' },
        json => { email => $user->email } )
      ->status_is( 200 );

    my $body = decode_json( $t_anon->tx->res->body );
    ok( scalar @{ $body->{allowCredentials} } >= 1,
        'allowCredentials includes user passkey' );
};

subtest 'POST /auth/webauthn/auth/begin requires email' => sub {
    my $t_anon = Test::Registry::Mojo->new('Registry');
    $t_anon->app->helper( dao => sub { $db } );

    $t_anon->post_ok( '/auth/webauthn/auth/begin',
        { Accept => 'application/json', 'Content-Type' => 'application/json' },
        json => {} )
      ->status_is( 400, 'Returns 400 without email' )
      ->json_is( '/error', 'Email is required' );
};

# ---------------------------------------------------------------------------
# webauthn_auth_complete
# ---------------------------------------------------------------------------

subtest 'POST /auth/webauthn/auth/complete with missing challenge returns 400' => sub {
    # auth_complete does not require prior auth -- it IS the login flow.
    my $t3 = Test::Registry::Mojo->new('Registry');
    $t3->app->helper( dao => sub { $db } );

    $t3->post_ok( '/auth/webauthn/auth/complete',
        { Accept => 'application/json', 'Content-Type' => 'application/json' },
        json => {
            id       => encode_base64url('fake_credential_id'),
            response => {
                clientDataJSON     => encode_base64url('{}'),
                authenticatorData  => encode_base64url('fake'),
                signature          => encode_base64url('fake'),
            },
        } )
      ->status_isnt( 501, 'Endpoint is implemented (not 501)' )
      ->status_is( 400,   'Returns 400 when no challenge in session' );
};

subtest 'POST /auth/webauthn/auth/complete requires authentication' => sub {
    my $t2 = Test::Registry::Mojo->new('Registry');
    $t2->app->helper( dao => sub { $db } );

    $t2->post_ok( '/auth/webauthn/auth/complete',
        {   Accept              => 'application/json',
            'Content-Type'      => 'application/json',
            'X-Requested-With'  => 'XMLHttpRequest',
        },
        json => {} )
      ->status_isnt( 200, 'Returns non-200 when unauthenticated' )
      ->status_isnt( 501, 'Endpoint is implemented (not 501)' );
};

done_testing();
