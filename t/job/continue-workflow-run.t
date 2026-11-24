# ABOUTME: The continue_workflow_run job, run by Minion's own worker against real Postgres,
# ABOUTME: continues a parked run in its tenant's schema from its latest step until a person is needed.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::PricingProbe qw( state_platform_terms );
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::DAO::OutcomeDefinition;
use Registry::DAO::Payment;
use Registry::Service::Stripe;
use Mojo::IOLoop;
use Mojo::Promise;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

my $admin = Registry::DAO::User->create( $dao->db, {
    username => "cwr_admin_$$", email => "cwr_admin_$$\@test.example",
    name => 'CWR Admin', user_type => 'admin' } );

my $slug_a = "cwr_a_$$";
Registry::DAO::Tenant->provision( $dao->db, {
    name => "CWR A $$", slug => $slug_a, users => [$admin],
    stripe_connect_account_id => "acct_cwr_$$",
    stripe_charges_enabled => 1, stripe_details_submitted => 1 } );
state_platform_terms( $dao->db, $slug_a, { rate => 0 } );
my $adb = $dao->connect_schema($slug_a)->db;

my $t      = Test::Registry::Mojo->new('Registry');
my $minion = $t->app->minion;

# An outcome definition whose one field is required: a base step carrying it
# waits for a person unless the run already holds that field.
sub requiring ( $db, $field ) {
    Registry::DAO::OutcomeDefinition->create( $db, {
        name   => "needs $field $$",
        schema => { fields => [ { id => $field, type => 'text', required => 1 } ] },
    } )->id;
}

# A workflow in $db's schema whose steps are [ slug, class, outcome id ].
my $wf_n = 0;
sub workflow ( $db, @steps ) {
    $wf_n++;
    my $wf = Registry::DAO::Workflow->create( $db, {
        name => "CWR $wf_n", slug => "cwr-$wf_n-$$", description => 'driver test' } );
    for my $s (@steps) {
        my ( $slug, $class, $outcome ) = @$s;
        $wf->add_step( $db, {
            slug  => $slug,
            class => $class // 'Registry::DAO::WorkflowStep',
            ( $outcome ? ( outcome_definition_id => $outcome ) : () ),
        } );
    }
    return $wf;
}

# A run whose first step a person has answered with $data.
sub parked_run ( $db, $wf, $data ) {
    my $run = $wf->new_run( $db, {} );
    $run->process( $db, $wf->first_step($db), $data );
    return $run;
}

sub reload ( $db, $run ) { Registry::DAO::WorkflowRun->find( $db, { id => $run->id } ) }

sub run_count ($db) { $db->query('SELECT count(*) FROM workflow_runs')->array->[0] }

# Enqueues the job and has Minion's worker perform it; returns its info.
sub run_job ($args) {
    my $id = $minion->enqueue( continue_workflow_run => [$args] );
    $minion->perform_jobs( { id => $id } );
    return $minion->job($id)->info;
}

subtest 'continues parked run from latest step' => sub {
    my $wf = workflow( $adb,
        ['step-1'], ['step-2'], [ 'step-3', undef, requiring( $adb, 'from_step_1' ) ] );
    my $run    = parked_run( $adb, $wf, { from_step_1 => 'kept' } );
    my $before = run_count($adb);

    my $info = run_job( { tenant => $slug_a, run_id => $run->id } );

    is $info->{state}, 'finished', 'job finished' or diag explain $info->{result};
    is_deeply $info->{result},
        { run_id => $run->id, stopped_at => 'step-3', reason => 'completed' },
        'job reports the run completed at its last step';
    my $after = reload( $adb, $run );
    is $after->latest_step($adb)->slug, 'step-3', 'the same run advanced through steps 2 and 3';
    ok $after->completed($adb), 'and it is complete';
    is $after->data->{from_step_1}, 'kept', 'step 3 was handed the data the run carried to it';
    is run_count($adb), $before, 'no new run was created';
};

subtest 'a step waiting for input leaves the run parked there' => sub {
    my $wf = workflow( $adb,
        ['ask'], ['pass-on'], [ 'wait', undef, requiring( $adb, 'answer' ) ], ['after'] );
    my $run = parked_run( $adb, $wf, { given => 1 } );

    my $info = run_job( { tenant => $slug_a, run_id => $run->id } );

    is $info->{state}, 'finished', 'job finished' or diag explain $info->{result};
    is_deeply $info->{result},
        { run_id => $run->id, stopped_at => 'wait', reason => 'needs_person' },
        'job reports the step that needs a person';
    is reload( $adb, $run )->latest_step($adb)->slug, 'pass-on',
        'the run stays parked before the waiting step';
};

# --- the shipped Payment step, which returns a Mojo::Promise -----------------
#
# Stripe is answered locally, as the payment-step tests do: the step asks for
# the intent the run names and settles the payment row from Stripe's answer.

my $parent = Registry::DAO::User->create( $adb, {
    username => "cwr_parent_$$", email => "cwr_parent_$$\@test.example",
    name => 'CWR Parent', user_type => 'parent' } );

my $intent_n = 0;
# A pending payment row on intent $intent, and the run data that sends the
# Payment step down its settle-from-Stripe path.
sub payment_data ($intent) {
    my $payment = Registry::DAO::Payment->create( $adb, {
        user_id      => $parent->id,
        amount_cents => 5000,
        metadata     => { tenant_slug => $slug_a },
    } );
    $payment->update( $adb, { stripe_payment_intent_id => $intent } );
    return ( $payment, { user_id => $parent->id, payment_id => $payment->id,
                         payment_intent_id => $intent } );
}

subtest 'a Payment step promise is awaited before the next step runs' => sub {
    my $intent = 'pi_cwr_ok_' . ++$intent_n;
    my ( $payment, $data ) = payment_data($intent);
    my $wf  = workflow( $adb, ['before'],
        [ 'payment', 'Registry::DAO::WorkflowSteps::Payment' ], ['after'] );
    my $run = parked_run( $adb, $wf, $data );

    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent_async = sub ( $s, $id ) {
        my $p = Mojo::Promise->new;
        Mojo::IOLoop->next_tick( sub {
            $p->resolve( { id => $id, status => 'succeeded', amount => 5000 } ) } );
        return $p;
    };

    my $info = run_job( { tenant => $slug_a, run_id => $run->id } );

    is $info->{state}, 'finished', 'job finished' or diag explain $info->{result};
    is_deeply $info->{result},
        { run_id => $run->id, stopped_at => 'after', reason => 'completed' },
        'the run went on past the payment step to the end';
    is Registry::DAO::Payment->find( $adb, { id => $payment->id } )->status, 'completed',
        'the payment step settled from the resolved Stripe answer';
    is reload( $adb, $run )->latest_step($adb)->slug, 'after', 'the run is complete';
};

subtest 'continues a run in the registry platform schema' => sub {
    my $rdb = $dao->db;
    my $wf  = workflow( $rdb,
        ['step-1'], ['step-2'], [ 'step-3', undef, requiring( $rdb, 'from_step_1' ) ] );
    my $run = parked_run( $rdb, $wf, { from_step_1 => 'kept' } );

    my $info = run_job( { tenant => 'registry', run_id => $run->id } );

    is_deeply $info->{result},
        { run_id => $run->id, stopped_at => 'step-3', reason => 'completed' },
        'the platform run is continued to its end'
        or diag explain $info->{result};
    is reload( $rdb, $run )->latest_step($rdb)->slug, 'step-3', 'on that same run';
};

done_testing;
