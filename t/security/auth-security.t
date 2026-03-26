#!/usr/bin/env perl
# ABOUTME: Security tests for the auth system — token entropy validation,
# ABOUTME: hash storage verification, and anti-enumeration checks.
use 5.42.0;
use warnings;
use utf8;

use Test::More;
use Test::Mojo;

use lib qw(lib t/lib);
use Test::Registry::DB;

use Registry::DAO::MagicLinkToken;
use Registry::DAO::ApiKey;
use Registry::DAO::User;
use Registry::DAO::Workflow;
use Digest::SHA qw(sha256_hex);
use Mojo::Home;
use YAML::XS qw(Load);

my $tdb = Test::Registry::DB->new;
my $dao = $tdb->db;
my $db  = $dao->db;

# Import workflows so route redirects resolve properly
my $wf_dir = Mojo::Home->new->child('workflows');
for my $file ( $wf_dir->list_tree->grep(qr/\.ya?ml$/)->each ) {
    my $data = Load( $file->slurp );
    next if $data->{draft};
    Registry::DAO::Workflow->from_yaml( $dao, $file->slurp );
}

my $user = Registry::DAO::User->create($db, {
    username  => 'security_test_user',
    email     => 'security@example.com',
    name      => 'Security Tester',
    password  => 'test_password',
});

subtest 'Token entropy - magic links have sufficient randomness' => sub {
    my @tokens;
    for (1..10) {
        my ($obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
            user_id => $user->id,
            purpose => 'login',
        });
        push @tokens, $plaintext;
    }

    # All tokens should be unique
    my %seen;
    $seen{$_}++ for @tokens;
    is(scalar keys %seen, 10, 'All 10 generated tokens are unique');

    # Tokens should be reasonably long (32 bytes base64url >= 40 chars)
    ok(length($tokens[0]) >= 40, 'Token has sufficient length for 256-bit entropy');
};

subtest 'API key entropy - keys have sufficient randomness' => sub {
    my @keys;
    for (1..10) {
        my ($obj, $plaintext) = Registry::DAO::ApiKey->generate($db, {
            user_id => $user->id,
            name    => "Entropy Test $_",
        });
        push @keys, $plaintext;
    }

    my %seen;
    $seen{$_}++ for @keys;
    is(scalar keys %seen, 10, 'All 10 generated API keys are unique');
};

subtest 'Token hashing - plaintext not stored in database' => sub {
    my ($obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'login',
    });

    isnt($obj->token_hash, $plaintext, 'Stored hash differs from plaintext');
    is($obj->token_hash, sha256_hex($plaintext), 'Hash is SHA-256 of plaintext');
};

subtest 'API key hashing - plaintext not stored in database' => sub {
    my ($obj, $plaintext) = Registry::DAO::ApiKey->generate($db, {
        user_id => $user->id,
        name    => 'Hash test key',
    });

    isnt($obj->key_hash, $plaintext, 'Stored key hash differs from plaintext');
    is($obj->key_hash, sha256_hex($plaintext), 'Key hash is SHA-256 of plaintext');
};

subtest 'Magic link email enumeration prevention' => sub {
    my $t = Test::Mojo->new('Registry');

    # Request for existing email
    $t->post_ok('/auth/magic/request' => form => {
        email => 'security@example.com',
    });
    my $existing_status = $t->tx->res->code;

    # Request for non-existing email
    $t->post_ok('/auth/magic/request' => form => {
        email => 'nonexistent-xyz@example.com',
    });
    my $missing_status = $t->tx->res->code;

    is($existing_status, $missing_status,
        'Same HTTP status for existing and non-existing email');
};

done_testing();
