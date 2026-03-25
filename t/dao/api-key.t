#!/usr/bin/env perl
# ABOUTME: Unit tests for ApiKey DAO — creation with one-time plaintext reveal,
# ABOUTME: hash lookup, scope bitvector checks, expiry, and prefix storage.
use 5.42.0;
use warnings;
use utf8;

use Test::More;
use Test::Exception;

use lib qw(lib t/lib);
use Test::Registry::DB;

use Registry::DAO::ApiKey;
use Registry::DAO::User;

my $t  = Test::Registry::DB->new;
my $db = $t->db;

my $user = Registry::DAO::User->create($db, {
    username => 'api_key_test_user',
    email    => 'apikey@example.com',
    name     => 'API Key Tester',
    password => 'test_password',
});

subtest 'Generate an API key' => sub {
    my ($key_obj, $plaintext) = Registry::DAO::ApiKey->generate($db, {
        user_id => $user->id,
        name    => 'My Test Key',
        scopes  => 3,  # read + write
    });

    ok($key_obj, 'Key object created');
    ok($plaintext, 'Plaintext key returned');
    like($plaintext, qr/^rk_live_/, 'Key has correct prefix format');
    is($key_obj->user_id, $user->id, 'Correct user_id');
    is($key_obj->name, 'My Test Key', 'Correct name');
    is($key_obj->scopes, 3, 'Correct scopes bitvector');
    ok($key_obj->key_prefix, 'Has key_prefix stored');
    is(length($key_obj->key_prefix), 8, 'Prefix is 8 characters');
};

subtest 'Find by plaintext key (hash lookup)' => sub {
    my ($key_obj, $plaintext) = Registry::DAO::ApiKey->generate($db, {
        user_id => $user->id,
        name    => 'Lookup Test Key',
    });

    my $found = Registry::DAO::ApiKey->find_by_plaintext($db, $plaintext);
    ok($found, 'Found key by plaintext hash lookup');
    is($found->id, $key_obj->id, 'Correct key found');
};

subtest 'Scope bitvector checks' => sub {
    my ($key_obj, $plaintext) = Registry::DAO::ApiKey->generate($db, {
        user_id => $user->id,
        name    => 'Scoped Key',
        scopes  => 0b00110101,  # read + delete + enrollment + reporting
    });

    ok($key_obj->has_scope(1),  'Has read scope');
    ok(!$key_obj->has_scope(2), 'Does not have write scope');
    ok($key_obj->has_scope(4),  'Has delete scope');
    ok($key_obj->has_scope(16), 'Has enrollment scope');
    ok($key_obj->has_scope(32), 'Has reporting scope');
    ok(!$key_obj->has_scope(8), 'Does not have admin scope');

    # Zero scopes means no restrictions (full access)
    my ($full_key, $full_pt) = Registry::DAO::ApiKey->generate($db, {
        user_id => $user->id,
        name    => 'Full Access Key',
        scopes  => 0,
    });
    ok($full_key->has_scope(1), 'Zero-scope key has read (unrestricted)');
    ok($full_key->has_scope(8), 'Zero-scope key has admin (unrestricted)');
};

subtest 'Expired key detected' => sub {
    my ($key_obj, $plaintext) = Registry::DAO::ApiKey->generate($db, {
        user_id    => $user->id,
        name       => 'Expiring Key',
        expires_in => -1,  # already expired
    });

    ok($key_obj->is_expired, 'Key reports as expired');
};

subtest 'Key without expiry never expires' => sub {
    my ($key_obj, $plaintext) = Registry::DAO::ApiKey->generate($db, {
        user_id => $user->id,
        name    => 'Permanent Key',
    });

    ok(!$key_obj->is_expired, 'Key without expiry is not expired');
};

subtest 'Update last_used_at' => sub {
    my ($key_obj, $plaintext) = Registry::DAO::ApiKey->generate($db, {
        user_id => $user->id,
        name    => 'Usage Tracking Key',
    });

    ok(!$key_obj->last_used_at, 'No last_used_at initially');

    my $updated = $key_obj->touch($db);
    ok($updated->last_used_at, 'last_used_at set after touch');
};

done_testing();
