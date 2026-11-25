#!/usr/bin/env perl
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::Offer;
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO::WorkflowSteps::PricingPlanSelection;
use Registry::DAO::WorkflowSteps::TenantPayment;

my $test_db = Test::Registry::DB->new;
my $dao = $test_db->db;

# The resource every platform offer to tenants buys.
my $PAYMENT_PROCESSING = '00000000-0000-0000-0001-000000000001';

subtest 'Integration test setup' => sub {
    # A published platform offer to tenants beside Solo. No monthly base:
    # signup takes no card, so it lists no offer that would need one.
    my $offer = Registry::DAO::Offer->create( $dao->db, { name => 'Registry Enterprise' } );
    my $enterprise = $offer->draft( $dao->db, offer_terms( $PAYMENT_PROCESSING,
        price_cents   => 0,
        payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => 0.04 } ],
    ) )->publish( $dao->db );

    ok $enterprise->id, 'Enterprise offer published';
};

subtest 'Full tenant signup integration test' => sub {
    # Create tenant signup workflow
    my $workflow = Registry::DAO::Workflow->create($dao->db, {
        name => 'Integration Test Tenant Signup',
        slug => 'integration-test-tenant-signup',
        description => 'Test workflow for full pricing plan selection integration'
    });

    # Add pricing plan selection step
    my $pricing_step = Registry::DAO::WorkflowStep->create($dao->db, {
        workflow_id => $workflow->id,
        slug => 'pricing',
        class => 'Registry::DAO::WorkflowSteps::PricingPlanSelection',
        description => 'Select pricing plan'
    });

    # Add payment step that depends on pricing
    my $payment_step = Registry::DAO::WorkflowStep->create($dao->db, {
        workflow_id => $workflow->id,
        slug => 'payment',
        class => 'Registry::DAO::WorkflowSteps::TenantPayment',
        description => 'Payment processing',
        depends_on => $pricing_step->id
    });

    # Set first step
    $workflow->update($dao->db, { first_step => 'pricing' });

    # Create a workflow run
    my $run = $workflow->new_run($dao->db);

    # Set up initial workflow data (as if coming from previous steps)
    $run->update_data($dao->db, {
        name => 'Test Enterprise Organization',
        admin_email => 'admin@enterprise.test',
        billing_email => 'billing@enterprise.test'
    });

    # Step 1: Test pricing plan selection
    my $pricing_step_obj = $workflow->get_step($dao->db, { slug => 'pricing' });

    # Get available plans
    my $pricing_result = $pricing_step_obj->process($dao->db, {});
    ok $pricing_result->{data}->{pricing_plans}, 'Pricing plans available';
    cmp_ok scalar(@{$pricing_result->{data}->{pricing_plans}}), '>=', 1, 'At least one pricing plan available';

    # By name. This file publishes its own Enterprise offer and the shipped seed
    # publishes Solo beside it, so [0] is a statement about Solo rather than
    # about the plan this subtest selects.
    my ($enterprise_plan) = grep { $_->{plan_name} eq 'Registry Enterprise' }
        @{ $pricing_result->{data}->{pricing_plans} };
    ok $enterprise_plan, 'Enterprise plan available';
    is $enterprise_plan->{amount_cents}, 0, 'Plan has no monthly base';

    # Select the enterprise plan through the run (which merges returned data)
    my $selection_result = $run->process($dao->db, $pricing_step_obj, {
        selected_plan_id => $enterprise_plan->{id}
    });

    ok !$selection_result->{_validation_errors}, 'No errors when selecting plan';

    # Only the version id is carried; its terms are re-read where quoted.
    is $run->data->{selected_offer_version}, $enterprise_plan->{id},
        'the chosen offer version is carried in workflow data';

    # Step 2: Test payment step uses selected plan
    my $payment_step_obj = $workflow->get_step($dao->db, { slug => 'payment' });

    # Get payment configuration
    my $payment_config = $payment_step_obj->get_subscription_config($dao->db, $run);

    is $payment_config->{plan_name}, 'Registry Enterprise', 'Payment uses selected plan name';
    is $payment_config->{monthly_amount}, 0, 'Payment uses selected plan amount';
    ok !exists $payment_config->{$_}, "An offer version declares no $_" for qw( trial_days billing_cycle );
    is $payment_config->{formatted_price}, 'Free', 'Payment formats price correctly';
    is $payment_config->{description}, '$0 a month, 4% of each payment you take',
        'Payment describes the selected version from its own terms';

    # Test payment data preparation
    my $payment_data = $payment_step_obj->prepare_payment_data($dao->db, $run);

    ok $payment_data->{billing_summary}, 'Billing summary prepared';
    is $payment_data->{billing_summary}->{organization_name}, 'Test Enterprise Organization', 'Organization name correct';
    is $payment_data->{billing_summary}->{plan_details}->{plan_name}, 'Registry Enterprise', 'Plan details use selected plan';
    is $payment_data->{billing_summary}->{plan_details}->{formatted_price}, 'Free', 'Plan price formatted correctly';
};

subtest 'Backwards compatibility test' => sub {
    # Create workflow without pricing plan selection step
    my $legacy_workflow = Registry::DAO::Workflow->create($dao->db, {
        name => 'Legacy Tenant Signup',
        slug => 'legacy-tenant-signup',
        description => 'Test workflow for backwards compatibility'
    });

    my $legacy_payment_step = Registry::DAO::WorkflowStep->create($dao->db, {
        workflow_id => $legacy_workflow->id,
        slug => 'payment',
        class => 'Registry::DAO::WorkflowSteps::TenantPayment',
        description => 'Payment processing'
    });

    $legacy_workflow->update($dao->db, { first_step => 'payment' });

    # Create run without pricing plan data
    my $legacy_run = $legacy_workflow->new_run($dao->db);
    $legacy_run->update_data($dao->db, {
        name => 'Legacy Organization',
        admin_email => 'admin@legacy.test'
    });

    # With no choice carried the payment step quotes the first listed offer,
    # the published Solo version, from its own terms.
    my $legacy_payment_obj = $legacy_workflow->get_step($dao->db, { slug => 'payment' });
    my $legacy_config = $legacy_payment_obj->get_subscription_config($dao->db, $legacy_run);

    is $legacy_config->{plan_name}, 'Solo', 'Quotes the Solo offer';
    is $legacy_config->{monthly_amount}, 0, 'At its $0 price';
    is $legacy_config->{formatted_price}, 'Free', 'Formatted as free';

    ok 1, 'Backwards compatibility maintained';
};

done_testing;