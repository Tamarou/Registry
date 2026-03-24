#!/usr/bin/env perl
# ABOUTME: Tests that parent payment intents use Stripe Connect direct charges.
# ABOUTME: Verifies application_fee_amount is calculated from tenant's PricingPlan.
use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Payment;
use Registry::DAO::Tenant;
use Registry::DAO::TenantStripeAccount;
use Registry::DAO::PricingPlan;
use Registry::DAO::PricingRelationship;
use Registry::DAO::User;

my $test_db = Test::Registry::DB->new;
my $dao = $test_db->db;
my $db = $dao->db;

# Create tenant with Stripe account
my $tenant = Registry::DAO::Tenant->create($db, {
    name => 'Direct Charge Org',
    slug => 'direct_charge_org',
});

Registry::DAO::TenantStripeAccount->create($db, {
    tenant_id => $tenant->id,
    stripe_account_id => 'acct_direct_charge_test',
    charges_enabled => 1,
});

# Create primary user for the tenant (review fix #5: consumer_id is a user ID)
my $primary_user = Registry::DAO::User->create($db, {
    username => 'dc_admin',
    passhash => '$2b$12$DummyHash',
    user_type => 'admin',
});
$tenant->set_primary_user($db, $primary_user);

# Create pricing plan and relationship
my $platform_uuid = '00000000-0000-0000-0000-000000000000';
my $solo_plan = Registry::DAO::PricingPlan->create($db, {
    plan_name => 'Solo',
    plan_type => 'standard',
    plan_scope => 'tenant',
    pricing_model_type => 'percentage',
    amount => 0,
    currency => 'USD',
    pricing_configuration => { revenue_share_percent => 2.5 },
    metadata => {},
});

# Review fix #5: consumer_id is the tenant's primary USER ID, not tenant ID
Registry::DAO::PricingRelationship->create($db, {
    provider_id => $platform_uuid,
    consumer_id => $primary_user->id,
    pricing_plan_id => $solo_plan->id,
    status => 'active',
    metadata => { plan_type => 'tenant_subscription' },
});

subtest 'calculate_application_fee resolves from PriceOps' => sub {
    my $fee = Registry::DAO::Payment->calculate_application_fee($db, $tenant->id, 10000);
    is $fee, 250, 'Application fee is 2.5% of $100 (250 cents)';
};

subtest 'calculate_application_fee for different amounts' => sub {
    is Registry::DAO::Payment->calculate_application_fee($db, $tenant->id, 5000), 125, '2.5% of $50';
    is Registry::DAO::Payment->calculate_application_fee($db, $tenant->id, 15000), 375, '2.5% of $150';
    is Registry::DAO::Payment->calculate_application_fee($db, $tenant->id, 100), 2, '2.5% of $1 rounds to 2 cents';
};

subtest 'calculate_application_fee falls back for tenant without pricing' => sub {
    my $tenant2 = Registry::DAO::Tenant->create($db, {
        name => 'No Pricing Org',
        slug => 'no_pricing_org',
    });
    # No pricing relationship -- should fall back to default 2.5%
    my $fee = Registry::DAO::Payment->calculate_application_fee($db, $tenant2->id, 10000);
    is $fee, 250, 'Falls back to default 2.5% without pricing relationship';
};

subtest 'build_connect_charge_params includes stripe_account and application_fee' => sub {
    my $params = Registry::DAO::Payment->build_connect_charge_params($db, {
        tenant_id => $tenant->id,
        amount => 10000,
        currency => 'usd',
        description => 'Art Class Enrollment',
    });

    is $params->{amount}, 10000, 'Amount passed through';
    is $params->{currency}, 'usd', 'Currency passed through';
    is $params->{application_fee_amount}, 250, 'Application fee calculated from PriceOps';
    is $params->{stripe_account}, 'acct_direct_charge_test', 'Stripe account ID from tenant';
};

subtest 'build_connect_charge_params fails for tenant without Stripe account' => sub {
    my $tenant3 = Registry::DAO::Tenant->create($db, {
        name => 'No Stripe Org',
        slug => 'no_stripe_org_dc',
    });

    my $params = eval {
        Registry::DAO::Payment->build_connect_charge_params($db, {
            tenant_id => $tenant3->id,
            amount => 10000,
        });
    };

    ok $@, 'Dies for tenant without Stripe account';
    like $@, qr/no.*stripe.*account|charges.*not.*enabled/i, 'Error message is descriptive';
};

done_testing;
