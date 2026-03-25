#!/usr/bin/env perl
# ABOUTME: Unit tests for MagicLinkToken DAO — creation, hash verification,
# ABOUTME: consumption, expiry enforcement, and single-use semantics.
use 5.42.0;
use warnings;
use utf8;

use Test::More;
use Test::Exception;

use lib qw(lib t/lib);
use Test::Registry::DB;

use Registry::DAO::MagicLinkToken;
use Registry::DAO::User;

my $t  = Test::Registry::DB->new;
my $db = $t->db;

my $user = Registry::DAO::User->create($db, {
    username => 'magic_link_test_user',
    email    => 'magic@example.com',
    name     => 'Magic Link Tester',
    password => 'test_password',
});

subtest 'Generate a magic link token' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'login',
    });

    ok($token_obj, 'Token object created');
    ok($plaintext, 'Plaintext token returned');
    ok(length($plaintext) > 20, 'Plaintext has sufficient length');
    is($token_obj->user_id, $user->id, 'Correct user_id');
    is($token_obj->purpose, 'login', 'Correct purpose');
    ok(!$token_obj->consumed_at, 'Not yet consumed');
    ok($token_obj->expires_at, 'Has expiry timestamp');

    # Plaintext should NOT be stored — only the hash
    isnt($token_obj->token_hash, $plaintext, 'Stored hash differs from plaintext');
};

subtest 'Find by plaintext token (hash lookup)' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'invite',
    });

    my $found = Registry::DAO::MagicLinkToken->find_by_plaintext($db, $plaintext);
    ok($found, 'Found token by plaintext hash lookup');
    is($found->id, $token_obj->id, 'Correct token found');
    is($found->purpose, 'invite', 'Correct purpose');
};

subtest 'Consume a token (single-use)' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'login',
    });

    my $consumed = $token_obj->consume($db);
    ok($consumed->consumed_at, 'consumed_at set after consumption');

    # Attempting to consume again should fail
    dies_ok { $consumed->consume($db) } 'Cannot consume token twice';
};

subtest 'Expired token rejected' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id    => $user->id,
        purpose    => 'login',
        expires_in => -1,  # already expired (negative hours)
    });

    ok($token_obj->is_expired, 'Token reports as expired');
    dies_ok { $token_obj->consume($db) } 'Cannot consume expired token';
};

subtest 'Valid token not expired' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'login',
    });

    ok(!$token_obj->is_expired, 'Fresh token is not expired');
};

subtest 'Purpose constraint enforced' => sub {
    dies_ok {
        Registry::DAO::MagicLinkToken->generate($db, {
            user_id => $user->id,
            purpose => 'invalid_purpose',
        });
    } 'Invalid purpose rejected by database constraint';
};

subtest 'Cascade delete with user' => sub {
    my $temp_user = Registry::DAO::User->create($db, {
        username => 'temp_magic_user',
        email    => 'tempmagic@example.com',
        name     => 'Temp User',
        password => 'test_password',
    });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $temp_user->id,
        purpose => 'login',
    });

    # Delete profile first (FK constraint), then the user (cascades to magic_link_tokens)
    $db->db->delete('user_profiles', { user_id => $temp_user->id });
    $db->db->delete('users', { id => $temp_user->id });

    my $orphan = Registry::DAO::MagicLinkToken->find_by_plaintext($db, $plaintext);
    ok(!$orphan, 'Token cascade-deleted with user');
};

done_testing();
