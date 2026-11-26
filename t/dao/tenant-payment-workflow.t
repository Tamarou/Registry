#!/usr/bin/env perl

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;

use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::WorkflowSteps::TenantPayment;
use Registry::PriceOps::PlatformTerms qw( platform_offers_to_tenants );
use Registry::DAO::Workflow;
use Registry::DAO::Offer;
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO::WorkflowRun;
use JSON;

my $test_db = Test::Registry::DB->new;
my $dao = $test_db->db;
my $db = $dao->db;

# Create test tenant with schema cloning  
$db->query(q{
    INSERT INTO registry.tenants (id, name, slug)
    VALUES ('00000000-0000-4000-8000-000000000001', 'Test Tenant', 'test-tenant')
});
$db->query("SET search_path TO tenant_00000000_0000_4000_8000_000000000001, registry, public");

# Create test workflow using create method
my $workflow = Registry::DAO::Workflow->create($db, {
    name => 'Test Tenant Payment',
    slug => 'test-tenant-payment',
    description => 'Test workflow for payment step'
});

my $payment_step = Registry::DAO::WorkflowSteps::TenantPayment->create($db, {
    workflow_id => $workflow->id,
    slug => 'payment',
    class => 'Registry::DAO::WorkflowSteps::TenantPayment',
    description => 'Payment step'
});

# A run that carries no choice yet: the review page quotes the offer it
# preselects, Solo on day one.
my $no_plan_run = Registry::DAO::WorkflowRun->create($db, {
    workflow_id => $workflow->id,
    data => encode_json({})
});

subtest 'TenantPayment workflow step creation' => sub {
    plan tests => 2;

    isa_ok($payment_step, 'Registry::DAO::WorkflowSteps::TenantPayment');
    can_ok($payment_step, qw(process prepare_payment_data get_subscription_config));
};

subtest 'Subscription configuration' => sub {
    plan tests => 7;

    my $config = $payment_step->get_subscription_config($db, $no_plan_run);

    ok($config, 'Configuration returned');
    is($config->{plan_name}, 'Solo', 'Plan name correct');
    is($config->{monthly_amount}, 0, 'Monthly amount is $0 (Solo tier)');
    is($config->{currency}, 'usd', 'Currency is USD');
    ok(!exists $config->{$_}, "No $_: the platform runs no subscription") for qw( trial_days billing_cycle );
    ok($config->{features} && @{$config->{features}} > 0, 'Features list provided');
};

subtest 'revenue share percent is the rate the platform sells' => sub {
    plan tests => 3;

    # The constant must be gone; the rate is the offer version's own.
    ok( !Registry::DAO::WorkflowSteps::TenantPayment->can('REVENUE_SHARE_PERCENT'),
        'REVENUE_SHARE_PERCENT constant removed from TenantPayment'
    );

    my $config = $payment_step->get_subscription_config($db, $no_plan_run);

    # Read from the database rather than written here as a literal: a test that
    # hardcodes 2.5 passes on the day someone changes the plan and the page
    # starts quoting something else.
    my $solo_percent = platform_offers_to_tenants($db)->[0]{fraction} * 100;

    is( $config->{revenue_share_percent}, $solo_percent,
        'the page quotes the preselected Solo version rate'
    );

    # The old failure mode this guards: with no plan resolved the config fell
    # back to the platform Free plan, so signup quoted 0% while the charge path
    # -- had anything linked a plan -- charged something else.
    isnt( $config->{revenue_share_percent}, 0,
        'and not the Free plan 0% that a NULL plan link resolves to'
    );
};

subtest 'Payment data preparation' => sub {
    plan tests => 4;
    
    # Create test workflow run using create method
    my $run = Registry::DAO::WorkflowRun->create($db, {
        workflow_id => $workflow->id,
        data => encode_json({
            profile => {
                organization_name => 'Test Organization',
                subdomain => 'test-org',
                billing_email => 'billing@test.org'
            }
        })
    });
    
    my $data = $payment_step->prepare_payment_data($db, $run);
    
    ok($data, 'Payment data prepared');
    ok($data->{billing_summary}, 'Billing summary included');
    is($data->{billing_summary}->{organization_name}, 'Test Organization', 'Organization name correct');
    ok($data->{subscription_config}, 'Subscription config included');
};

subtest 'Initial payment page process' => sub {
    plan tests => 2;

    my $run = Registry::DAO::WorkflowRun->create($db, {
        workflow_id => $workflow->id,
        data => encode_json({
            profile => {
                organization_name => 'Test Organization',
                billing_email => 'billing@test.org'
            }
        })
    });

    my $result = $payment_step->prepare_payment_data($db, $run);

    ok($result, 'Process result returned');
    ok(exists $result->{billing_summary}, 'Billing summary in result');
};

subtest 'Validation error handling' => sub {
    plan tests => 2;
    
    # Create run without required profile data
    my $run = Registry::DAO::WorkflowRun->create($db, {
        workflow_id => $workflow->id,
        data => encode_json({})
    });
    
    # Test prepare_payment_data with missing profile data
    my $result = $payment_step->prepare_payment_data($db, $run);
    
    ok($result, 'Result returned even with missing data');
    # Should have default values for missing organization name
    is($result->{billing_summary}->{organization_name}, 'Your Organization', 'Default organization name used');
};

# A platform offer to tenants a signup may choose: no monthly base, since
# signup takes no card.
sub buyable_offer ( $name, $fraction ) {
    my $offer = Registry::DAO::Offer->create( $db, { name => $name } );
    return $offer->draft( $db, offer_terms( '00000000-0000-0000-0001-000000000001',
        price_cents   => 0,
        payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => $fraction } ],
    ) )->publish($db);
}

subtest 'Subscription config follows the run in hand, not the newest run' => sub {
    plan tests => 4;

    # Two published platform offers. The run carries only a version id and
    # the version is re-read, so these have to be real current offers.
    my $mine_plan  = buyable_offer( 'Studio Test Tier', 0.03 );
    my $their_plan = buyable_offer( 'Empire Test Tier', 0.04 );

    my $mine = Registry::DAO::WorkflowRun->create($db, {
        workflow_id => $workflow->id,
        data => encode_json({
            profile => {
                organization_name => 'My Organization',
                billing_email     => 'me@example.org',
            },
            selected_offer_version => $mine_plan->id,
        })
    });

    # Another visitor starts a signup after mine and picks a different plan.
    my $theirs = Registry::DAO::WorkflowRun->create($db, {
        workflow_id => $workflow->id,
        data => encode_json({
            selected_offer_version => $their_plan->id,
        })
    });

    # latest_run orders by created_at, and two rows written in the same instant
    # would tie; make theirs unambiguously the newest.
    $db->query(
        q{UPDATE workflow_runs SET created_at = created_at + interval '1 minute' WHERE id = ?},
        $theirs->id
    );

    my $data = $payment_step->prepare_payment_data($db, $mine);
    is($data->{subscription_config}{plan_name}, 'Studio Test Tier',
        'payment page prices my run with my plan');
    is($data->{subscription_config}{revenue_share_percent}, 3,
        'and with my rate');
    is($data->{billing_summary}{plan_details}{plan_name}, 'Studio Test Tier',
        'billing summary agrees');

    my $config = eval { $payment_step->get_subscription_config($db, $mine) };
    is(($config ? $config->{plan_name} : undef), 'Studio Test Tier',
        'get_subscription_config prices the run it is handed');
};

my $SOLO_V2 = '9bc4069a-f0a7-0026-3a84-aeb0d0732995';    # solo-grants-workflow-set's

# A run that has reached the review page, enough for provisioning to succeed.
sub signup_run ($slug, %extra) {
    return Registry::DAO::WorkflowRun->create( $db, {
        workflow_id => $workflow->id,
        data        => {
            name            => "Studio $slug",
            subdomain       => $slug,
            admin_name      => 'Signup Admin',
            admin_email     => "${slug}_admin\@test.example",
            admin_username  => "${slug}_admin",
            admin_user_type => 'admin',
            profile         => { name => "Studio $slug", slug => $slug },
            %extra,
        },
    } );
}

sub tenant_row ($slug) {
    return $db->query( q{
        SELECT * FROM registry.tenants WHERE slug = ?
    }, $slug )->hash;
}

subtest 'signup provisions with no card or subscription' => sub {
    local $ENV{MOJO_MODE} = 'development';
    delete local $ENV{STRIPE_SECRET_KEY};
    delete local $ENV{STRIPE_PUBLISHABLE_KEY};

    my $run = signup_run('nocard');

    # The review step offers no card collection.
    my $page = $payment_step->prepare_template_data( $db, $run );
    ok !exists $page->{$_}, "the review page carries no $_"
        for qw( show_payment_form stripe_publishable_key client_secret setup_intent_id );
    ok !$payment_step->can($_), "the step has no $_"
        for qw( create_setup_intent handle_setup_completion check_stripe_service check_session_validity );

    my $result = $run->process( $db, $payment_step, { offer_version => $SOLO_V2 } );
    ok $result->{tenant}, 'the tenant is provisioned';

    my $data = Registry::DAO::WorkflowRun->find( $db, { id => $run->id } )->data;
    ok !exists $data->{subscription}, 'no subscription is written into the run';
    ok !exists $data->{payment_setup}, 'and no card setup';

    my $tenant = tenant_row('nocard');
    ok $tenant, 'the tenant row exists';
    ok !exists $tenant->{$_}, "and carries no $_: the platform runs no subscription"
        for qw( stripe_subscription_id billing_status trial_ends_at );
};

subtest 'client card or subscription fields ignored' => sub {
    local $ENV{MOJO_MODE} = 'development';
    delete local $ENV{STRIPE_SECRET_KEY};
    delete local $ENV{STRIPE_PUBLISHABLE_KEY};

    # A subscription an earlier signup page stored: those pages keep what is
    # posted to them, so a client can put one in the run.
    my $run = signup_run( 'clientcard', subscription => {
        stripe_subscription_id => 'sub_client_chosen',
        trial_ends_at          => time() + 86400,
        status                 => 'trialing',
    } );

    my $result = $run->process( $db, $payment_step, {
        offer_version          => $SOLO_V2,
        collect_payment_method => 1,
        setup_intent_id        => 'seti_client_chosen',
        payment_method_id      => 'pm_client_chosen',
        'subscription[stripe_subscription_id]' => 'sub_client_posted',
    } );
    ok $result->{tenant}, 'the tenant is provisioned';

    my $data = Registry::DAO::WorkflowRun->find( $db, { id => $run->id } )->data;
    ok !exists $data->{$_}, "the review step stores no $_"
        for qw( setup_intent_id payment_method_id payment_setup ), 'subscription[stripe_subscription_id]';

    my $tenant = tenant_row('clientcard');
    ok $tenant, 'the tenant row exists';
    ok !exists $tenant->{$_}, "and no client-chosen $_ reaches it"
        for qw( stripe_subscription_id billing_status trial_ends_at );
};

# Signup takes no card, so an offer with a monthly base is not one it lists.
subtest 'a priced platform offer is not listed' => sub {
    my $priced = Registry::DAO::Offer->create( $db, { name => 'Priced Test Tier' } )->draft( $db,
        offer_terms( '00000000-0000-0000-0001-000000000001',
            price_cents   => 4900,
            payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => 0.02 } ],
        ) )->publish($db);

    ok !( grep { $_->{id} eq $priced->id } platform_offers_to_tenants($db)->@* ), 'it is not listed';
    my $run = signup_run( 'pricedchoice', selected_offer_version => $priced->id );
    isnt $payment_step->get_subscription_config( $db, $run )->{plan_name}, 'Priced Test Tier',
        'and a run carrying it is not quoted it';
};

done_testing();
