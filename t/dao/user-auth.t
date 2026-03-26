#!/usr/bin/env perl
# ABOUTME: Tests for passwordless user creation and auth-related
# ABOUTME: relationship accessors (passkeys, magic_link_tokens, api_keys).
use 5.42.0;
use warnings;
use utf8;

use Test::More;
use Test::Exception;

use lib qw(lib t/lib);
use Test::Registry::DB;

use Registry::DAO::User;
use Registry::DAO::Passkey;
use Registry::DAO::MagicLinkToken;
use Registry::DAO::ApiKey;

my $t  = Test::Registry::DB->new;
my $db = $t->db;

subtest 'Create user without password (passwordless)' => sub {
    my $user = Registry::DAO::User->create($db, {
        username => 'passwordless_user',
        email    => 'nopass@example.com',
        name     => 'Passwordless User',
    });

    ok($user, 'User created without password');
    ok($user->id, 'Has id');
    is($user->username, 'passwordless_user', 'Correct username');
    is($user->email, 'nopass@example.com', 'Correct email');
};

subtest 'Create user WITH password still works' => sub {
    my $user = Registry::DAO::User->create($db, {
        username => 'password_user',
        email    => 'withpass@example.com',
        name     => 'Password User',
        password => 'test_password123',
    });

    ok($user, 'User created with password');
    ok($user->check_password('test_password123'), 'Password verification works');
};

subtest 'User passkeys accessor' => sub {
    my $user = Registry::DAO::User->create($db, {
        username => 'passkey_rel_user',
        email    => 'passkey_rel@example.com',
        name     => 'Passkey Rel User',
        password => 'test_password',
    });

    my @passkeys = $user->passkeys($db);
    is(scalar @passkeys, 0, 'No passkeys initially');

    Registry::DAO::Passkey->create($db, {
        user_id       => $user->id,
        credential_id => pack('H*', 'aa11bb22cc33dd44'),
        public_key    => pack('H*', 'ee55ff66'),
        device_name   => 'Laptop',
    });

    @passkeys = $user->passkeys($db);
    is(scalar @passkeys, 1, 'One passkey after creation');
    is($passkeys[0]->device_name, 'Laptop', 'Correct device name');
};

subtest 'User magic_link_tokens accessor' => sub {
    my $user = Registry::DAO::User->create($db, {
        username => 'magic_rel_user',
        email    => 'magic_rel@example.com',
        name     => 'Magic Rel User',
        password => 'test_password',
    });

    Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'login',
    });

    my @tokens = $user->magic_link_tokens($db);
    is(scalar @tokens, 1, 'One magic link token');
    is($tokens[0]->purpose, 'login', 'Correct purpose');
};

subtest 'User api_keys accessor' => sub {
    my $user = Registry::DAO::User->create($db, {
        username => 'apikey_rel_user',
        email    => 'apikey_rel@example.com',
        name     => 'ApiKey Rel User',
        password => 'test_password',
    });

    Registry::DAO::ApiKey->generate($db, {
        user_id => $user->id,
        name    => 'Test Key',
    });

    my @keys = $user->api_keys($db);
    is(scalar @keys, 1, 'One API key');
    is($keys[0]->name, 'Test Key', 'Correct key name');
};

done_testing();
