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

my $test_db = Test::Registry::DB->new;
my $dao = $test_db->db;

# The resource every platform offer to tenants buys.
my $PAYMENT_PROCESSING = '00000000-0000-0000-0001-000000000001';

# A platform offer to tenants: a draft, published unless asked otherwise.
sub platform_offer ( $name, $cents, %opt ) {
    my $offer = Registry::DAO::Offer->create( $dao->db, { name => $name } );
    my $version = $offer->draft( $dao->db, offer_terms( $PAYMENT_PROCESSING,
        price_cents   => $cents,
        payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => 0.02 } ],
    ) );
    return $opt{draft} ? $version : $version->publish( $dao->db );
}

subtest 'Test data setup' => sub {
    ok platform_offer( 'Registry Basic',        10000 )->id, 'Basic offer published';
    ok platform_offer( 'Registry Professional', 20000 )->id, 'Professional offer published';
    ok platform_offer( 'Registry Enterprise',   50000 )->id, 'Enterprise offer published';
};

subtest 'Create workflow with pricing plan selection step' => sub {
    # Create tenant signup workflow
    my $workflow = Registry::DAO::Workflow->create($dao->db, {
        name => 'Test Tenant Signup',
        slug => 'test-tenant-signup',
        description => 'Test workflow for tenant signup with pricing plan selection'
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

    ok $workflow->id, 'Workflow created';
    ok $pricing_step->id, 'Pricing plan selection step created';
    ok $payment_step->id, 'Payment step created';
};

subtest 'PricingPlanSelection step functionality' => sub {
    my $workflow = Registry::DAO::Workflow->find($dao->db, { slug => 'test-tenant-signup' });
    my $run = $workflow->new_run($dao->db);

    # Set up minimal workflow data
    $run->update_data($dao->db, {
        name => 'Test Organization',
        admin_email => 'admin@test.org'
    });

    my $pricing_step = $workflow->get_step($dao->db, { slug => 'pricing' });

    # Test initial page load (no form data)
    my $result = $pricing_step->process($dao->db, {});

    is $result->{next_step}, $pricing_step->id, 'Stays on pricing step initially';
    ok $result->{data}, 'Data prepared for template';
    ok $result->{data}->{pricing_plans}, 'Pricing plans available';
    cmp_ok scalar(@{$result->{data}->{pricing_plans}}), '>=', 3, 'At least three pricing plans available';

    # By name, not by position. This file publishes its own offers, and the
    # shipped seed publishes Solo alongside them -- so an index is a statement
    # about what else happens to be on offer, which is not what this subtest is
    # about. Their relative order is asserted directly instead.
    my $plans = $result->{data}->{pricing_plans};
    my %pos   = map { $plans->[$_]{plan_name} => $_ } 0 .. $#$plans;

    ok defined $pos{'Registry Basic'},        'Basic is on offer';
    ok defined $pos{'Registry Professional'}, 'Professional is on offer';
    ok defined $pos{'Registry Enterprise'},   'Enterprise is on offer';

    cmp_ok $pos{'Registry Basic'}, '<', $pos{'Registry Professional'},
        'Basic sorts before Professional';
    cmp_ok $pos{'Registry Professional'}, '<', $pos{'Registry Enterprise'},
        'Professional sorts before Enterprise';

    # Verify plan data structure
    my $basic_plan = $plans->[ $pos{'Registry Basic'} ];
    ok $basic_plan->{id}, 'Plan has ID';
    is $basic_plan->{amount_cents}, 10000, 'Plan amount correct';
    is $basic_plan->{currency}, 'usd', 'Plan currency correct';
    is $basic_plan->{pricing_configuration}{percentage}, '0.02', 'Plan carries its version rate';
};

subtest 'Plan selection processing' => sub {
    my $workflow = Registry::DAO::Workflow->find($dao->db, { slug => 'test-tenant-signup' });
    my $run = $workflow->new_run($dao->db);

    # Set up workflow data
    $run->update_data($dao->db, {
        name => 'Test Organization',
        admin_email => 'admin@test.org'
    });

    my $pricing_step = $workflow->get_step($dao->db, { slug => 'pricing' });

    # Get available plans to select from
    my $initial_result = $pricing_step->process($dao->db, {});
    my $plans = $initial_result->{data}->{pricing_plans};
    my ($professional_plan) =
        grep { $_->{plan_name} eq 'Registry Professional' } @$plans;
    ok $professional_plan, 'Professional is on offer to select';

    # Test plan selection through the run (which merges the returned data)
    my $result = $run->process($dao->db, $pricing_step, {
        selected_plan_id => $professional_plan->{id}
    });

    ok !$result->{_validation_errors}, 'No errors when selecting valid plan';

    # Only the version id is carried; its terms are re-read where quoted.
    is $run->data->{selected_offer_version}, $professional_plan->{id},
        'the chosen offer version is stored in workflow data';
};

subtest 'Error handling' => sub {
    my $workflow = Registry::DAO::Workflow->find($dao->db, { slug => 'test-tenant-signup' });
    my $run = $workflow->new_run($dao->db);

    my $pricing_step = $workflow->get_step($dao->db, { slug => 'pricing' });

    # Test missing plan selection (should show pricing page, not error)
    my $result = $pricing_step->process($dao->db, {});

    ok !$result->{errors}, 'No errors when no plan data submitted';
    is $result->{next_step}, $pricing_step->id, 'Stays on pricing step for initial page load';

    # Test empty plan selection
    $result = $pricing_step->process($dao->db, {
        selected_plan_id => ''
    });

    ok $result->{_validation_errors}, 'Error when empty plan selected';
    like $result->{_validation_errors}->[0], qr/please select/i, 'Appropriate error message';

    # Test invalid plan ID
    $result = $pricing_step->process($dao->db, {
        selected_plan_id => 'invalid-plan-id'
    });

    ok $result->{_validation_errors}, 'Error when invalid plan selected';
    like $result->{_validation_errors}->[0], qr/not available/i, 'Appropriate error message for invalid plan';

    # An offer version that exists but is not published
    my $inactive_plan = platform_offer( 'Inactive Plan', 15000, draft => 1 );

    $result = $pricing_step->process($dao->db, {
        selected_plan_id => $inactive_plan->id
    });

    ok $result->{_validation_errors}, 'Error when plan not available for platform';
    like $result->{_validation_errors}->[0], qr/not available/i, 'Appropriate error message for unavailable plan';
};

subtest 'Template method' => sub {
    my $workflow = Registry::DAO::Workflow->find($dao->db, { slug => 'test-tenant-signup' });
    my $pricing_step = $workflow->get_step($dao->db, { slug => 'pricing' });

    is $pricing_step->template, 'tenant-signup/pricing', 'Correct template path';
};

done_testing;