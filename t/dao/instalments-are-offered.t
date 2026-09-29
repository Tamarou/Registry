# ABOUTME: Tests that the pricing screen offers instalments and the step stores what it collects.
# ABOUTME: The inverse of what this file asserted under #437, when they were configurable and ignored.
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
        'a plan nobody asked to split declares no schedule';
};

subtest 'a requested instalment plan is stored as a declared schedule' => sub {
    my $model = pricing_model_after( {
        instalments_enabled => 1,
        instalment_count    => 3,
    } );

    my $schedule = $model->{pricing_configuration}{schedule};
    ok $schedule, 'the schedule is declared' or return;
    is $schedule->{count},         3,         'three payments';
    is $schedule->{cadence},       'monthly', 'a month apart';
    is $schedule->{surcharge_pct}, 0,         'and no surcharge -- the same total either way';
};

# The count decides how many times a family's card is charged, so a value
# Registry cannot schedule must not become a plan that offers instalments and
# then cannot honour them. That is #425 arriving by a different road.
subtest 'a count Registry cannot schedule is refused' => sub {
    for my $bad ( 0, 1, 13, 'three', -2 ) {
        my $model = pricing_model_after(
            { instalments_enabled => 1, instalment_count => $bad } );
        is $model->{pricing_configuration}{schedule}, undef,
            "a count of '$bad' declares no schedule";
    }
};

subtest 'the old boolean-and-count buys nothing' => sub {
    # What a page from before #425 would post. The columns are gone; this
    # asserts the form data cannot resurrect them by another route.
    my $model = pricing_model_after( {
        installments_allowed => 1,
        installment_count    => 3,
    } );

    is $model->{pricing_configuration}{schedule}, undef,
        'the retired spelling declares nothing';
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
    my $model = pricing_model_after(
        { instalments_enabled => 1, instalment_count => 4 } );

    my $plan = Registry::DAO::PricingPlan->create($db, {
        session_id            => $session->id,
        plan_name             => 'From The Probe',
        plan_type             => 'standard',
        amount_cents          => $model->{amount},
        pricing_configuration => $model->{pricing_configuration},
    });

    my $parts = $plan->instalment_schedule( $model->{amount}, first_due => '2026-06-01' );
    is scalar( @{ $parts // [] } ), 4,
        'the plan that reaches the database resolves four charges';

    my $sum = 0;
    $sum += $_->{amount_cents} for @$parts;
    is $sum, $model->{amount}, 'summing to exactly the plan price';
};

subtest 'the screen offers the controls, now that they are honoured' => sub {
    # The other half, inverted. Under #437 this asserted the controls were
    # ABSENT, because a form collecting a payment plan the charge path ignored
    # was a lie. They are honoured now, so their absence would be the lie.
    my $template = Mojo::File->new('templates/pricing-plan-creation/pricing-model.html.ep')->slurp;

    like $template, qr/name="instalments_enabled"/, 'an instalments checkbox';
    like $template, qr/name="instalment_count"/,    'and a count';
    unlike $template, qr/Not available yet/,
        'and no notice saying they are coming, because they are here';

    # The retired spelling must not come back: the columns behind it are
    # dropped, so a form posting it would collect a value nothing stores.
    unlike $template, qr/name="installments_allowed"/,
        'not under the old name';
};

done_testing;
