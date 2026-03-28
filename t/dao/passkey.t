#!/usr/bin/env perl
# ABOUTME: Unit tests for the Passkey DAO — CRUD, sign count tracking,
# ABOUTME: cascade delete, and multi-passkey-per-user support.
use 5.42.0;
use warnings;
use utf8;

use Test::More;
use Test::Exception;

use lib qw(lib t/lib);
use Test::Registry::DB;

use Registry::DAO::Passkey;
use Registry::DAO::User;

my $t  = Test::Registry::DB->new;
my $db = $t->db;

# Create a test user (passwordless — no passhash required)
my $user = Registry::DAO::User->create($db, {
    username => 'passkey_test_user',
    email    => 'passkey@example.com',
    name     => 'Passkey Tester',
});
ok($user, 'Created test user');

subtest 'Create a passkey' => sub {
    my $passkey = Registry::DAO::Passkey->create($db, {
        user_id       => $user->id,
        credential_id => pack('H*', 'deadbeef01020304'),
        public_key    => pack('H*', 'cafebabe05060708'),
        device_name   => 'Test MacBook',
    });

    ok($passkey, 'Passkey created');
    ok($passkey->id, 'Has UUID id');
    is($passkey->user_id, $user->id, 'Correct user_id');
    is($passkey->sign_count, 0, 'Initial sign count is 0');
    is($passkey->device_name, 'Test MacBook', 'Device name stored');
    ok($passkey->created_at, 'Has created_at timestamp');
    ok(!$passkey->last_used_at, 'No last_used_at initially');
};

subtest 'Find passkey by credential_id' => sub {
    my $cred_id = pack('H*', 'deadbeef01020304');
    my $found = Registry::DAO::Passkey->find($db, {
        credential_id => $cred_id,
    });

    ok($found, 'Found passkey by credential_id');
    is($found->user_id, $user->id, 'Correct user');
};

subtest 'Update sign count' => sub {
    my $cred_id = pack('H*', 'deadbeef01020304');
    my $passkey = Registry::DAO::Passkey->find($db, {
        credential_id => $cred_id,
    });

    my $updated = $passkey->update_sign_count($db, 1);
    is($updated->sign_count, 1, 'Sign count updated to 1');
    ok($updated->last_used_at, 'last_used_at set after use');

    # Sign count must always increase (replay protection)
    dies_ok { $passkey->update_sign_count($db, 0) }
        'Rejects sign count regression (replay protection)';
};

subtest 'Multiple passkeys per user' => sub {
    my $passkey2 = Registry::DAO::Passkey->create($db, {
        user_id       => $user->id,
        credential_id => pack('H*', 'aabbccdd11223344'),
        public_key    => pack('H*', '11223344aabbccdd'),
        device_name   => 'Test iPhone',
    });

    ok($passkey2, 'Second passkey created');

    my @all = Registry::DAO::Passkey->for_user($db, $user->id);
    is(scalar @all, 2, 'User has 2 passkeys');
};

subtest 'Credential ID uniqueness' => sub {
    dies_ok {
        Registry::DAO::Passkey->create($db, {
            user_id       => $user->id,
            credential_id => pack('H*', 'deadbeef01020304'),  # duplicate
            public_key    => pack('H*', 'ffffffffffffffff'),
        });
    } 'Duplicate credential_id rejected';
};

subtest 'Cascade delete with user' => sub {
    my $temp_user = Registry::DAO::User->create($db, {
        username => 'temp_passkey_user',
        email    => 'temp@example.com',
        name     => 'Temp User',
    });

    Registry::DAO::Passkey->create($db, {
        user_id       => $temp_user->id,
        credential_id => pack('H*', 'eeeeeeeeeeeeeeee'),
        public_key    => pack('H*', 'dddddddddddddddd'),
    });

    # Delete the user (profile must go first due to FK constraint)
    $db->db->delete('user_profiles', { user_id => $temp_user->id });
    $db->db->delete('users', { id => $temp_user->id });

    my $orphan = Registry::DAO::Passkey->find($db, {
        credential_id => pack('H*', 'eeeeeeeeeeeeeeee'),
    });
    ok(!$orphan, 'Passkey cascade-deleted with user');
};

done_testing();
