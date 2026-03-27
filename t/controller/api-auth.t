#!/usr/bin/env perl
# ABOUTME: Tests for bearer token API authentication via the Authorization header.
# ABOUTME: Covers valid keys, invalid keys, expired keys, and the session fallback path.
use 5.42.0;
use warnings;
use utf8;

use Test::More;

use lib qw(lib t/lib);
use Test::Registry::Mojo;
use Test::Registry::DB;

use Registry::DAO::User;
use Registry::DAO::ApiKey;

my $tdb = Test::Registry::DB->new;
my $db  = $tdb->db;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $db });

my $user = Registry::DAO::User->create($db->db, {
    username  => 'api_auth_user',
    email     => 'apiauth@example.com',
    name      => 'API Auth User',
    user_type => 'admin',
    password  => 'test_password',
});

subtest 'Valid bearer token authenticates' => sub {
    my ($key_obj, $plaintext) = Registry::DAO::ApiKey->generate($db->db, {
        user_id => $user->id,
        name    => 'Valid Test Key',
    });

    $t->get_ok('/admin/dashboard' => {
        Authorization => "Bearer $plaintext",
    })->status_isnt(401, 'Not rejected with valid bearer token')
      ->status_isnt(302, 'Not redirected to login');
};

subtest 'Invalid bearer token returns 401 for API clients' => sub {
    $t->get_ok('/admin/dashboard' => {
        Authorization      => 'Bearer rk_live_totally_invalid_key',
        'X-Requested-With' => 'XMLHttpRequest',
    })->status_is(401, 'Invalid key returns 401');
};

subtest 'Expired bearer token returns 401' => sub {
    my ($key_obj, $plaintext) = Registry::DAO::ApiKey->generate($db->db, {
        user_id    => $user->id,
        name       => 'Expired Test Key',
        expires_in => -1,
    });

    $t->get_ok('/admin/dashboard' => {
        Authorization      => "Bearer $plaintext",
        'X-Requested-With' => 'XMLHttpRequest',
    })->status_is(401, 'Expired key returns 401');
};

subtest 'No bearer token falls through to session auth' => sub {
    # Without bearer token or session, should get redirected to login
    my $t2 = Test::Registry::Mojo->new('Registry');
    $t2->app->helper(dao => sub { $db });
    $t2->get_ok('/admin/dashboard')
       ->status_is(302, 'Redirected without any auth');
};

done_testing();
