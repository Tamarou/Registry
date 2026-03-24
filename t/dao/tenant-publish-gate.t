#!/usr/bin/env perl
# ABOUTME: Tests that tenants cannot publish programs without a connected Stripe account.
# ABOUTME: Verifies the charges_enabled gate on program visibility.
use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Tenant;
use Registry::DAO::TenantStripeAccount;

my $test_db = Test::Registry::DB->new;
my $dao = $test_db->db;
my $db = $dao->db;

subtest 'Tenant without Stripe account cannot accept payments' => sub {
    my $tenant = Registry::DAO::Tenant->create($db, {
        name => 'No Stripe Tenant',
        slug => 'no_stripe_tenant_pg',
    });

    ok !$tenant->can_accept_payments($db), 'Cannot accept payments without Stripe account';
};

subtest 'Tenant with incomplete onboarding cannot accept payments' => sub {
    my $tenant = Registry::DAO::Tenant->create($db, {
        name => 'Incomplete Stripe Tenant',
        slug => 'incomplete_stripe_pg',
    });

    Registry::DAO::TenantStripeAccount->create($db, {
        tenant_id => $tenant->id,
        stripe_account_id => 'acct_incomplete_pg',
        charges_enabled => 0,
    });

    ok !$tenant->can_accept_payments($db), 'Cannot accept payments with incomplete onboarding';
};

subtest 'Tenant with completed onboarding can accept payments' => sub {
    my $tenant = Registry::DAO::Tenant->create($db, {
        name => 'Complete Stripe Tenant',
        slug => 'complete_stripe_pg',
    });

    Registry::DAO::TenantStripeAccount->create($db, {
        tenant_id => $tenant->id,
        stripe_account_id => 'acct_complete_pg',
        charges_enabled => 1,
    });

    ok $tenant->can_accept_payments($db), 'Can accept payments with charges enabled';
};

done_testing;
