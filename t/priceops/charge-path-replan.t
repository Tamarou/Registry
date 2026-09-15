#!/usr/bin/env perl
# ABOUTME: The charge path re-resolves the selected plan instead of trusting run data.
# ABOUTME: A run started before a price change must charge the current price, not the remembered one.

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::PricingPlan;
use Mojo::JSON qw( encode_json );

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

$dao->import_workflows(['workflows/tenant-signup.yml']);
my $workflow = $dao->find( Workflow => { slug => 'tenant-signup' } );
my $payment  = Registry::DAO::WorkflowStep->find( $db,
    { workflow_id => $workflow->id, slug => 'payment' } );
my $pricing  = Registry::DAO::WorkflowStep->find( $db,
    { workflow_id => $workflow->id, slug => 'pricing' } );
ok $payment && $pricing, 'the signup payment and pricing steps exist'
    or BAIL_OUT 'workflow shape changed';

# The buyable tier from the shipped seed, reached the way the signup page does.
my ($solo) = grep { !$_->{metadata}{coming_soon} }
    @{ $pricing->prepare_pricing_data( $db, $workflow->new_run($db) )->{pricing_plans} };
ok $solo, 'the seed offers a buyable tier' or BAIL_OUT 'no buyable plan';

# A run that selected the plan and stored the blob, exactly as PricingPlanSelection does.
sub run_having_selected ( $snapshot ) {
    my $run = $workflow->new_run($db);
    $run->update_data( $db, { selected_pricing_plan => $snapshot } );
    return $run;
}

subtest 'a current selection is used' => sub {
    my $run = run_having_selected({
        id => $solo->{id}, plan_name => $solo->{plan_name},
        amount_cents => $solo->{amount_cents}, currency => 'USD',
    });

    my $config = $payment->get_subscription_config( $db, $run );
    is $config->{plan_name}, $solo->{plan_name}, 'the selected plan is what gets configured';
};

# The case with no adversary in it. A signup started before a price change and
# resumed after it charged the amount captured at selection while linking the
# plan whose rate had since moved -- displayed, charged and linked disagreeing
# with nobody doing anything wrong.
subtest 'a price changed after selection is re-read, not remembered' => sub {
    my $run = run_having_selected({
        id => $solo->{id}, plan_name => $solo->{plan_name},
        amount_cents => 999_99, currency => 'USD',
    });

    my $config = $payment->get_subscription_config( $db, $run );
    isnt $config->{monthly_amount}, 999_99,
        'the stale amount in run data is not what would be charged';
    is $config->{monthly_amount}, $solo->{amount_cents},
        'the plan row decides the price';
};

# validate_plan_selection refuses a coming_soon plan, but that guard lived only
# at the moment of selection. A run holding a plan that has since been marked
# coming_soon must not be able to charge it.
subtest 'a plan that became unavailable is not charged' => sub {
    my $shelved = Registry::DAO::PricingPlan->create( $db, {
        plan_scope => 'tenant', plan_name => 'Shelved Tier',
        amount_cents => 499_00, currency => 'USD',
        metadata => { coming_soon => 1 },
    } );

    my $run = run_having_selected({
        id => $shelved->id, plan_name => 'Shelved Tier',
        amount_cents => 499_00, currency => 'USD',
    });

    my $config = $payment->get_subscription_config( $db, $run );
    isnt $config->{monthly_amount}, 499_00,
        'the shelved tier is not what would be charged';
};

done_testing;
