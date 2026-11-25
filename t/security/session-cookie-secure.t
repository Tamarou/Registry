#!/usr/bin/env perl
# ABOUTME: The session cookie is Secure, HttpOnly and SameSite=Lax in every mode but
# ABOUTME: development and test, keyed on the mode and never on the request scheme.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Mojo::Cookie::Response;
use Mojo::File qw(path);

use Registry;
use Registry::DAO::User;
use Registry::DAO::MagicLinkToken;

my $tdb = Test::Registry::DB->new;
my $db  = $tdb->db;

# Production startup refuses to boot without a secret.
$ENV{MOJO_SECRET} = 'session-cookie-secure-test-secret';

my $user = Registry::DAO::User->create( $db->db, {
    username  => 'cookie_secure_user',
    email     => 'cookie_secure@example.com',
    name      => 'Cookie Secure User',
    password  => 'test_password',
} );

sub app_in ( $mode, $scheme = 'http' ) {
    my $t = Test::Registry::Mojo->new( Registry->new( mode => $mode ) );
    $t->app->helper( dao => sub { $db } );
    $t->ua->server->url($scheme);
    return $t;
}

sub set_cookies ( $t, $name ) {
    return grep { $_->name eq $name }
        map { @{ Mojo::Cookie::Response->parse($_) } }
        @{ $t->tx->res->headers->every_header('Set-Cookie') };
}

sub session_cookie ($t) {
    my ($cookie) = set_cookies( $t, $t->app->sessions->cookie_name );
    return $cookie;
}

sub hardened_ok ( $cookie, $what ) {
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    ok $cookie, "$what is set" or return;
    ok $cookie->secure,   "$what is Secure";
    ok $cookie->httponly, "$what is HttpOnly";
    is $cookie->samesite, 'Lax', "$what is SameSite=Lax";
}

sub magic_login ($t) {
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    my ( undef, $plaintext ) = Registry::DAO::MagicLinkToken->generate( $db->db, {
        user_id => $user->id,
        purpose => 'login',
    } );
    $t->get_ok("/auth/magic/$plaintext")->status_is(200);
    $t->post_ok("/auth/magic/$plaintext/complete")->status_is(302, 'login redirects');
}

subtest 'production session cookie after login is Secure, HttpOnly and SameSite=Lax' => sub {
    my $t = app_in( 'production', 'https' );
    magic_login($t);
    hardened_ok( session_cookie($t), 'session cookie after login' );
    $t->get_ok('/auth/api-keys')->status_is( 200, 'the session is usable over https' );
};

subtest 'development login over plain http keeps a usable session' => sub {
    my $t = app_in('development');
    magic_login($t);
    my $cookie = session_cookie($t);
    ok $cookie && !$cookie->secure, 'development session cookie is not Secure';
    $t->get_ok('/auth/api-keys')
      ->status_is( 200, 'the session survives the next plain-http request' );
};

subtest 'production cookie secure over plain http' => sub {
    my $t = app_in('production');
    $t->get_ok('/auth/login')->status_is(200);
    ok !$t->tx->req->headers->header('X-Forwarded-Proto'), 'no X-Forwarded-Proto sent';
    hardened_ok( session_cookie($t), 'session cookie over plain http' );
};

subtest 'non development mode cookie is secure' => sub {
    for my $mode (qw(staging prodution)) {
        my $t = app_in($mode);
        $t->get_ok('/auth/login')->status_is(200);
        hardened_ok( session_cookie($t), "session cookie in mode '$mode'" );
    }
};

subtest 'expiring session cookie is also secure' => sub {
    my $t = app_in( 'production', 'https' );
    magic_login($t);
    $t->post_ok('/auth/logout')->status_is( 302, 'logout redirects' );
    my $cookie = session_cookie($t);
    hardened_ok( $cookie, 'expiring session cookie' );
    ok $cookie && $cookie->expires <= time, 'the cookie expires the session';
};

subtest 'as tenant cookie secure in production' => sub {
    # The app reads as-tenant but never sets it. Should a setter appear, this
    # fails until it is given the session cookie's attributes and tested here.
    my @setters = grep { path($_)->slurp =~ /cookie\(\s*['"]as-tenant['"]\s*(?:=>|,)/ }
        ( path('lib')->list_tree->each, path('templates')->list_tree->each );
    is_deeply \@setters, [], 'no code sets the as-tenant cookie';

    my $t = app_in( 'production', 'https' );
    magic_login($t);
    $t->get_ok( '/' => { Cookie => 'as-tenant=registry' } );
    hardened_ok( $_, 'as-tenant cookie' ) for set_cookies( $t, 'as-tenant' );
    hardened_ok( session_cookie($t), 'session cookie alongside as-tenant' )
        if session_cookie($t);
};

done_testing;
