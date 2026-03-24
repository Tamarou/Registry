#!/usr/bin/env perl
# ABOUTME: Integration test for tenant signup flow without payment step.
# ABOUTME: Verifies flow goes landing -> profile -> team -> pricing -> review -> complete.
use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Registry::DAO::PricingPlan;
use Registry::DAO::PricingRelationship;
use Registry::DAO::TenantStripeAccount;
use Registry::DAO::Tenant;

my $test_db = Test::Registry::DB->new;
my $db = $test_db->db;

$db->import_workflows(['workflows/tenant-signup.yml']);

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $db });
$db->current_tenant('registry');

# Create Solo plan for pricing step
my $platform_uuid = '00000000-0000-0000-0000-000000000000';
my $platform_user_id = $db->db->query('SELECT gen_random_uuid()')->array->[0];
$db->db->query(q{
    INSERT INTO registry.users (id, username, passhash, user_type)
    VALUES (?, ?, ?, ?)
}, $platform_user_id, 'platform_admin_flow', '$2b$12$DummyHash', 'admin');
$db->db->query(q{
    INSERT INTO registry.user_profiles (user_id, email, name)
    VALUES (?, ?, ?)
}, $platform_user_id, 'admin@tinyartempire.com', 'Platform Admin');
$db->db->query(q{
    INSERT INTO registry.tenant_users (tenant_id, user_id, is_primary)
    VALUES (?, ?, ?)
}, $platform_uuid, $platform_user_id, 1);

my $solo_plan = Registry::DAO::PricingPlan->create($db->db, {
    plan_name => 'Solo',
    plan_type => 'standard',
    plan_scope => 'tenant',
    pricing_model_type => 'percentage',
    amount => 0,
    currency => 'USD',
    pricing_configuration => {
        revenue_share_percent => 2.5,
        billing_cycle => 'monthly',
        description => '2.5% of processed revenue.',
        features => ['Everything'],
    },
    metadata => { display_order => 1, featured => 1 },
});

Registry::DAO::PricingRelationship->create($db->db, {
    provider_id => $platform_uuid,
    consumer_id => $platform_user_id,
    pricing_plan_id => $solo_plan->id,
    status => 'active',
    metadata => { plan_type => 'tenant_subscription' },
});

subtest 'Full signup flow skips payment step' => sub {
    # Landing
    $t->post_ok('/tenant-signup')->status_is(302);
    my $url = $t->tx->res->headers->location;

    # Profile
    $t->get_ok($url)->status_is(200);
    $t->post_ok($url => form => {
        name => 'FlowTestOrg',
        billing_email => 'flow@test.com',
    })->status_is(302);
    $url = $t->tx->res->headers->location;

    # Team
    $t->get_ok($url)->status_is(200);
    $t->post_ok($url => form => {
        admin_name => 'Flow Admin',
        admin_email => 'admin@flowtest.com',
        admin_username => 'flowadmin',
        admin_password => 'testpass123',
    })->status_is(302);
    $url = $t->tx->res->headers->location;

    # Pricing
    like $url, qr{/pricing$}, 'reached pricing step';
    $t->get_ok($url)->status_is(200);
    $t->post_ok($url => form => {
        selected_plan_id => $solo_plan->id,
    })->status_is(302);
    $url = $t->tx->res->headers->location;

    # Review (no payment step!)
    like $url, qr{/review$}, 'reached review step (no payment step)';
    $t->get_ok($url)->status_is(200);
    $t->post_ok($url => form => {
        terms_accepted => 1,
    })->status_is(302);
    $url = $t->tx->res->headers->location;

    # Complete -- GET triggers tenant creation via prepare_template_data
    # (terminal workflow steps are never process()'d by the controller)
    like $url, qr{/complete$}, 'reached complete step';
    $t->get_ok($url)->status_is(200)
      ->content_like(qr/Stripe|Connect|account/i, 'Complete page prompts Stripe connection')
      ->content_unlike(qr/30-Day Free Trial|trial period/i, 'No trial language on complete page');
};

subtest 'RegisterTenant creates Stripe Connect account' => sub {
    # Check that the tenant created above has a Stripe account record
    # The slug is generated from the name; try multiple patterns
    my @all_tenants = Registry::DAO::Tenant->find($db->db, {});
    my $tenant = Registry::DAO::Tenant->find($db->db, { name => 'FlowTestOrg' });

    ok $tenant, 'Tenant was created by RegisterTenant step';

    if ($tenant) {
        my $stripe_acct = Registry::DAO::TenantStripeAccount->find_by_tenant($db->db, $tenant->id);
        ok $stripe_acct, 'Stripe Connect account record created during registration';

        if ($stripe_acct) {
            like $stripe_acct->stripe_account_id, qr/^acct_/, 'Stripe account ID has expected prefix'
                or diag 'Account ID: ' . ($stripe_acct->stripe_account_id // 'undef');
            is $stripe_acct->onboarding_status, 'not_started', 'Onboarding not yet started';
            ok !$stripe_acct->charges_enabled, 'Charges not yet enabled';
        }
    }
};

done_testing;
