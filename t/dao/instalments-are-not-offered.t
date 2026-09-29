# ABOUTME: Tests that instalments cannot be configured while they are not yet charged.
# ABOUTME: The resolver exists (t/dao/instalment-schedule.t); the collecting waits for the charging.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# Instalments are configurable in the schema, validated by PricingPlan, written by
# this step -- and read by nothing in the payment path, which charges the full
# amount. So a tenant who ticked "allow instalments" had parents charged 100% up
# front while the plan said otherwise (#425).
#
# The fix for that is a payment schedule and is tracked under #427. This is the
# interim: stop offering what cannot be delivered. The controls are gone from the
# screen, and the step refuses the value regardless -- because a removed control is
# no defence against a stale page, a back button, or a typed request.
my $workflow = Registry::DAO::Workflow->create($db, {
    name => 'Instalment Probe', slug => 'instalment-probe',
    description => 'Drives the pricing-model step',
});
Registry::DAO::WorkflowStep->create($db, {
    workflow_id => $workflow->id, slug => 'pricing-model',
    class => 'Registry::DAO::WorkflowSteps::PricingModel',
    description => 'Pricing model',
});
$workflow->update($db, { first_step => 'pricing-model' }, { id => $workflow->id });

# Re-found, because create() blesses into the base class and find() loads the
# subclass named in the `class` column.
my $step = Registry::DAO::WorkflowStep->find($db,
    { workflow_id => $workflow->id, slug => 'pricing-model' });
isa_ok $step, 'Registry::DAO::WorkflowSteps::PricingModel';

sub pricing_model_after ($form) {
    my $run = $workflow->new_run($db);
    $step->process( $db, { pricing_model_type => 'fixed', base_amount => 30000,
                           currency => 'USD', %$form }, $run );
    return $dao->find( WorkflowRun => { id => $run->id } )->data->{pricing_model};
}

subtest 'an ordinary submit stores no instalment plan' => sub {
    my $model = pricing_model_after( {} );
    ok $model, 'the step stored a pricing model';
    is $model->{pricing_configuration}{schedule}, undef,
        'and declares no payment schedule';
};

subtest 'a posted instalment plan is refused, not stored' => sub {
    # Exactly what a stale page would send, or a typed request. The controls
    # being gone is not a defence: the value would otherwise be stored, shown
    # back on the review step, and then ignored at the charge.
    #
    # Both spellings: the old boolean-and-count a page from before #425 would
    # post, and the declared shape that replaced it.
    my $model = pricing_model_after( {
        installments_allowed        => 1,
        installment_count           => 3,
        'schedule[count]'           => 3,
        'schedule[cadence]'         => 'monthly',
    } );

    is $model->{pricing_configuration}{schedule}, undef,
        'no schedule is declared, however it was asked for';
};

subtest 'the plan that reaches the database has no instalment terms' => sub {
    # Asserted on the plan rather than on the run, because the run is an
    # intermediate: what matters is that nothing with instalment terms is ever
    # created, since PricingPlan will happily store them and the payment path will
    # happily ignore them.
    require Registry::DAO::PricingPlan;

    my $session = $dao->create(Session => {
        name => 'Instalment Week', start_date => '2026-01-01', end_date => '2026-12-31',
        status => 'published', capacity => 10, metadata => {},
    });
    my $model = pricing_model_after( { installments_allowed => 1, installment_count => 4 } );

    my $plan = Registry::DAO::PricingPlan->create($db, {
        session_id            => $session->id,
        plan_name             => 'From The Probe',
        plan_type             => 'standard',
        amount_cents          => $model->{amount},
        pricing_configuration => $model->{pricing_configuration},
    });

    is $plan->payment_schedule, undef, 'the created plan offers no instalments';
    is $plan->instalment_schedule( $model->{amount} ), undef,
        'so nothing resolves a schedule for it';
};

subtest 'the screen no longer offers the controls' => sub {
    # The other half. A form that still collects this would show an operator an
    # option the step then silently drops, which is its own kind of lie.
    my $template = Mojo::File->new('templates/pricing-plan-creation/pricing-model.html.ep')->slurp;

    unlike $template, qr/name="installments_allowed"/,
        'no instalments checkbox';
    unlike $template, qr/name="installment_count"/,
        'no instalment count field';
    unlike $template, qr/name="schedule\[/,
        'and none in the declared shape that replaced them either';
    like $template, qr/Not available yet/,
        'and it says so, rather than the option simply vanishing';
};

done_testing;
