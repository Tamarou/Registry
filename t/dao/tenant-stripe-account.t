#!/usr/bin/env perl
# ABOUTME: Tests for TenantStripeAccount DAO -- Stripe Connect account state per tenant.
# ABOUTME: Covers create, find, status transitions, and charges_enabled checks.
use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::TenantStripeAccount;
use Registry::DAO::Tenant;

my $test_db = Test::Registry::DB->new;
my $dao = $test_db->db;
my $db = $dao->db;

# Create a test tenant
my $tenant = Registry::DAO::Tenant->create($db, {
    name => 'Test Org',
    slug => 'test-org-stripe',
});

subtest 'Create and retrieve Stripe account' => sub {
    my $account = Registry::DAO::TenantStripeAccount->create($db, {
        tenant_id => $tenant->id,
        stripe_account_id => 'acct_test_123',
    });

    ok $account, 'account created';
    is $account->stripe_account_id, 'acct_test_123', 'stripe account ID stored';
    is $account->onboarding_status, 'not_started', 'default onboarding status';
    ok !$account->charges_enabled, 'charges not enabled by default';
    ok !$account->details_submitted, 'details not submitted by default';
    is $account->account_type, 'standard', 'default account type is standard';
};

subtest 'Find by tenant' => sub {
    my $account = Registry::DAO::TenantStripeAccount->find_by_tenant($db, $tenant->id);
    ok $account, 'found by tenant ID';
    is $account->stripe_account_id, 'acct_test_123', 'correct account returned';
};

subtest 'Find by Stripe account ID' => sub {
    my $account = Registry::DAO::TenantStripeAccount->find($db, {
        stripe_account_id => 'acct_test_123'
    });
    ok $account, 'found by Stripe account ID';
    is $account->tenant_id, $tenant->id, 'correct tenant returned';
};

subtest 'Update onboarding status from webhook data' => sub {
    my $account = Registry::DAO::TenantStripeAccount->find_by_tenant($db, $tenant->id);

    $account->update_from_stripe($db, {
        charges_enabled => 1,
        payouts_enabled => 1,
        details_submitted => 1,
    });

    # Re-fetch to verify persistence
    my $updated = Registry::DAO::TenantStripeAccount->find_by_tenant($db, $tenant->id);
    ok $updated->charges_enabled, 'charges enabled after update';
    ok $updated->payouts_enabled, 'payouts enabled after update';
    ok $updated->details_submitted, 'details submitted after update';
    is $updated->onboarding_status, 'complete', 'onboarding status set to complete';
};

subtest 'Partial onboarding sets pending status' => sub {
    my $tenant2 = Registry::DAO::Tenant->create($db, {
        name => 'Partial Org',
        slug => 'partial-org-stripe',
    });
    my $account2 = Registry::DAO::TenantStripeAccount->create($db, {
        tenant_id => $tenant2->id,
        stripe_account_id => 'acct_test_456',
    });

    $account2->update_from_stripe($db, {
        charges_enabled => 0,
        payouts_enabled => 0,
        details_submitted => 1,
    });

    my $updated = Registry::DAO::TenantStripeAccount->find_by_tenant($db, $tenant2->id);
    is $updated->onboarding_status, 'pending', 'partial onboarding sets pending status';
    ok !$updated->charges_enabled, 'charges still not enabled';
};

subtest 'can_accept_payments convenience method' => sub {
    my $enabled = Registry::DAO::TenantStripeAccount->find_by_tenant($db, $tenant->id);
    ok $enabled->can_accept_payments, 'tenant with charges_enabled can accept payments';

    my $tenant3 = Registry::DAO::Tenant->create($db, {
        name => 'No Stripe Org',
        slug => 'no-stripe-org',
    });
    my $no_account = Registry::DAO::TenantStripeAccount->find_by_tenant($db, $tenant3->id);
    ok !$no_account, 'tenant without Stripe account returns undef';
};

done_testing;
