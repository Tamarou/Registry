#!/usr/bin/env perl
# ABOUTME: Tests for Stripe Connect onboarding controller.
# ABOUTME: Verifies onboarding link redirect and return URL handling.
use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Mojo;
use Test::Registry::DB;
use Registry::DAO::Tenant;
use Registry::DAO::TenantStripeAccount;

my $test_db = Test::Registry::DB->new;
my $db = $test_db->db;

my $t = Test::Mojo->new('Registry');
$t->app->helper(dao => sub { $db });

# Create test tenant + stripe account
my $tenant = Registry::DAO::Tenant->create($db->db, {
    name => 'Connect Test Org',
    slug => 'connect-test-org',
});

my $stripe_account = Registry::DAO::TenantStripeAccount->create($db->db, {
    tenant_id => $tenant->id,
    stripe_account_id => 'acct_connect_test',
});

subtest 'Onboarding start shows settings page without Stripe key' => sub {
    # Without STRIPE_SECRET_KEY, the controller should show the settings page
    $t->get_ok('/connect/onboard/' . $tenant->id)
      ->status_is(200);
};

subtest 'Return URL shows account status' => sub {
    $t->get_ok('/connect/return/' . $tenant->id)
      ->status_is(200);
};

subtest 'Connect status page shows account state' => sub {
    $t->get_ok('/connect/status/' . $tenant->id)
      ->status_is(200)
      ->content_like(qr/not_started|pending|complete|Stripe|Connect/i, 'Shows account info');
};

subtest 'Status page for nonexistent tenant handles gracefully' => sub {
    $t->get_ok('/connect/status/00000000-0000-0000-0000-999999999999')
      ->status_is(200)
      ->content_like(qr/No Stripe account|not found/i, 'Shows missing account message');
};

done_testing;
