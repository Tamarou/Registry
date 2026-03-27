#!/usr/bin/env perl
# ABOUTME: Integration test verifying that the login page offers passkey
# ABOUTME: registration and magic link sign-in as authentication methods.
use 5.42.0;
use warnings;
use utf8;

use Test::More;

use lib qw(lib t/lib);
use Test::Registry::Mojo;
use Test::Registry::DB;

my $tdb = Test::Registry::DB->new;
my $db  = $tdb->db;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $db });

subtest 'Login page offers passkey and magic link authentication' => sub {
    $t->get_ok('/auth/login')
      ->status_is(200)
      ->content_like(qr/passkey|webauthn|PublicKeyCredential/i,
        'Login page has passkey support')
      ->content_like(qr/email/i,
        'Login page has email input for magic link');
};

subtest 'Login page includes magic link form' => sub {
    $t->get_ok('/auth/login')
      ->status_is(200)
      ->element_exists('form', 'Login page has a form')
      ->element_exists('input[name=email]', 'Form has email input');
};

done_testing();
