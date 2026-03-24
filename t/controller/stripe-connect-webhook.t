#!/usr/bin/env perl
# ABOUTME: Tests for Stripe Connect account.updated webhook handling.
# ABOUTME: Verifies onboarding status updates via webhook events.
use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Mojo;
use Test::Registry::DB;
use Registry::DAO::Tenant;
use Registry::DAO::TenantStripeAccount;
use Mojo::JSON qw(encode_json);

my $test_db = Test::Registry::DB->new;
my $db = $test_db->db;

# Use Test::Mojo directly to avoid CSRF injection on JSON webhook posts
my $t = Test::Mojo->new('Registry');
$t->app->helper(dao => sub { $db });

# Create test tenant with Stripe account
my $tenant = Registry::DAO::Tenant->create($db->db, {
    name => 'Webhook Test Org',
    slug => 'webhook-test-org',
});

my $stripe_account = Registry::DAO::TenantStripeAccount->create($db->db, {
    tenant_id => $tenant->id,
    stripe_account_id => 'acct_webhook_test',
});

subtest 'account.updated webhook updates onboarding status' => sub {
    my $payload = encode_json({
        id => 'evt_test_account_updated',
        type => 'account.updated',
        data => {
            object => {
                id => 'acct_webhook_test',
                charges_enabled => \1,
                payouts_enabled => \1,
                details_submitted => \1,
            }
        }
    });

    $t->post_ok('/webhooks/stripe' => { 'Content-Type' => 'application/json' } => $payload)
      ->status_is(200);

    # Verify account was updated
    my $updated = Registry::DAO::TenantStripeAccount->find_by_tenant($db->db, $tenant->id);
    ok $updated->charges_enabled, 'charges_enabled updated via webhook';
    ok $updated->details_submitted, 'details_submitted updated via webhook';
    is $updated->onboarding_status, 'complete', 'onboarding status set to complete';
};

subtest 'account.updated for unknown account is handled gracefully' => sub {
    my $payload = encode_json({
        id => 'evt_test_unknown',
        type => 'account.updated',
        data => {
            object => {
                id => 'acct_unknown_account',
                charges_enabled => \1,
                details_submitted => \1,
            }
        }
    });

    $t->post_ok('/webhooks/stripe' => { 'Content-Type' => 'application/json' } => $payload)
      ->status_is(200);
};

done_testing;
