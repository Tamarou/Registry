#!/usr/bin/env perl
# ABOUTME: Integration test verifying that auth credentials in one tenant
# ABOUTME: do not grant access to another tenant's resources.
use 5.42.0;
use warnings;
use utf8;

use Test::More;

use lib qw(lib t/lib);
use Test::Registry::DB;
use Test::Registry::Fixtures;

use Registry::DAO;
use Registry::DAO::User;
use Registry::DAO::MagicLinkToken;

my $tdb = Test::Registry::DB->new;
my $db  = $tdb->db;

subtest 'Credentials isolated between tenant schemas' => sub {
    # Create two tenants with separate schemas
    my $tenant_a = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Tenant Alpha',
        slug => 'tenant_alpha',
    });
    my $tenant_b = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Tenant Beta',
        slug => 'tenant_beta',
    });

    ok($tenant_a, 'Tenant Alpha created');
    ok($tenant_b, 'Tenant Beta created');
    is($tenant_a->slug, 'tenant_alpha', 'Tenant Alpha has correct slug');
    is($tenant_b->slug, 'tenant_beta',  'Tenant Beta has correct slug');

    # Create a DAO scoped to tenant A's schema
    my $dao_a = Registry::DAO->new(url => $tdb->uri, schema => 'tenant_alpha');

    # Create a user and magic link token in tenant A
    my $user_a = Registry::DAO::User->create($dao_a->db, {
        username  => 'alpha_user',
        email     => 'alpha@example.com',
        name      => 'Alpha User',
        password  => 'test_password',
    });

    ok($user_a, 'User created in tenant_alpha schema');

    my ($token_a, $plaintext_a) = Registry::DAO::MagicLinkToken->generate($dao_a->db, {
        user_id => $user_a->id,
        purpose => 'login',
    });

    ok($token_a,     'Token created in tenant_alpha schema');
    ok($plaintext_a, 'Plaintext token returned for tenant_alpha');

    # Token should be findable in tenant A
    my $found_in_a = Registry::DAO::MagicLinkToken->find_by_plaintext($dao_a->db, $plaintext_a);
    ok($found_in_a, 'Token found in tenant_alpha schema');
    is($found_in_a->user_id, $user_a->id, 'Token belongs to correct user in tenant_alpha');

    # Token should NOT be findable in tenant B
    my $dao_b = Registry::DAO->new(url => $tdb->uri, schema => 'tenant_beta');
    my $found_in_b = Registry::DAO::MagicLinkToken->find_by_plaintext($dao_b->db, $plaintext_a);
    ok(!$found_in_b, 'Token NOT found in tenant_beta schema - isolation confirmed');

    # Similarly, a user from tenant A should not exist in tenant B
    my $user_in_b = Registry::DAO::User->find($dao_b->db, { username => 'alpha_user' });
    ok(!$user_in_b, 'User NOT found in tenant_beta schema - isolation confirmed');
};

subtest 'Tokens generated in different schemas are independent' => sub {
    # Create a DAO scoped to each schema
    my $dao_a = Registry::DAO->new(url => $tdb->uri, schema => 'tenant_alpha');
    my $dao_b = Registry::DAO->new(url => $tdb->uri, schema => 'tenant_beta');

    # Create a user in tenant B with the same username
    my $user_b = Registry::DAO::User->create($dao_b->db, {
        username  => 'alpha_user',
        email     => 'alpha_in_b@example.com',
        name      => 'Alpha User in B',
        password  => 'test_password',
    });

    ok($user_b, 'User with same username created in tenant_beta schema');

    # Generate tokens in each schema
    my $user_a = Registry::DAO::User->find($dao_a->db, { username => 'alpha_user' });
    ok($user_a, 'User found in tenant_alpha for token generation');

    my ($tok_a, $plain_a) = Registry::DAO::MagicLinkToken->generate($dao_a->db, {
        user_id => $user_a->id,
        purpose => 'login',
    });
    my ($tok_b, $plain_b) = Registry::DAO::MagicLinkToken->generate($dao_b->db, {
        user_id => $user_b->id,
        purpose => 'login',
    });

    # Cross-schema token lookups should fail
    my $a_token_in_b = Registry::DAO::MagicLinkToken->find_by_plaintext($dao_b->db, $plain_a);
    ok(!$a_token_in_b, 'Tenant A token not visible in tenant B schema');

    my $b_token_in_a = Registry::DAO::MagicLinkToken->find_by_plaintext($dao_a->db, $plain_b);
    ok(!$b_token_in_a, 'Tenant B token not visible in tenant A schema');
};

done_testing();
