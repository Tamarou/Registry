# ABOUTME: The continue_workflow_run job, run by Minion's own worker against real Postgres,
# ABOUTME: continues a parked run in its tenant's schema from its latest step until a person is needed.
# The Payment step's promise (awaited, and rejected) is proven against real
# Stripe in t/stripe-live/continue-workflow-run.t.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Mojo;
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::DAO::OutcomeDefinition;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

my $admin = Registry::DAO::User->create( $dao->db, {
    username => "cwr_admin_$$", email => "cwr_admin_$$\@test.example",
    name => 'CWR Admin', user_type => 'admin' } );

my $slug_a = "cwr_a_$$";
Registry::DAO::Tenant->provision( $dao->db, {
    name => "CWR A $$", slug => $slug_a, users => [$admin] } );
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

# --- refusals and guards -----------------------------------------------------

my $slug_b = "cwr_b_$$";
Registry::DAO::Tenant->provision( $dao->db, {
    name => "CWR B $$", slug => $slug_b, users => [$admin] } );
my $bdb = $dao->connect_schema($slug_b)->db;

# Where $run stands, to compare before and after a job that must not move it.
sub where ( $db, $run ) {
    my $r = reload( $db, $run );
    return { step => $r->latest_step($db)->slug, data => $r->data };
}

subtest 'missing run id fails with run not found' => sub {
    my $before = run_count($adb);
    my $info   = run_job( { tenant => $slug_a,
                            run_id => '00000000-0000-4000-8000-000000000000' } );

    is $info->{state}, 'failed', 'job failed';
    like $info->{result}, qr/run not found/, 'with a clear run not found error';
    is run_count($adb), $before, 'and no run was created';
};

subtest 'run of another tenant is not found' => sub {
    my $wf     = workflow( $adb, ['step-1'], ['step-2'] );
    my $run    = parked_run( $adb, $wf, { owner => 'a' } );
    my $parked = where( $adb, $run );
    my $b_runs = run_count($bdb);

    my $info = run_job( { tenant => $slug_b, run_id => $run->id } );

    is $info->{state}, 'failed', 'job failed';
    like $info->{result}, qr/run not found/, 'tenant B cannot see tenant A\'s run';
    is_deeply where( $adb, $run ), $parked, 'tenant A\'s run is exactly where it was parked';
    is run_count($bdb), $b_runs, 'and tenant B gained no run';
};

subtest 'malformed job args fail before connecting' => sub {
    my $wf     = workflow( $adb, ['step-1'], ['step-2'] );
    my $run    = parked_run( $adb, $wf, { owner => 'a' } );
    my $parked = where( $adb, $run );

    for my $case (
        [ 'no tenant',      { run_id => $run->id },                       qr/needs a tenant and a run_id/ ],
        [ 'no run_id',      { tenant => $slug_a },                        qr/needs a tenant and a run_id/ ],
        [ 'no args at all', undef,                                        qr/needs a tenant and a run_id/ ],
        [ 'non-UUID run',   { tenant => $slug_a, run_id => 'not-a-uuid' }, qr/run_id is not a UUID/ ],
        [ 'unknown tenant', { tenant => 'x; DROP SCHEMA registry', run_id => $run->id },
          qr/tenant is not a registered tenant/ ],
        [ 'tenant as an SQL operator', { tenant => { '!=' => 'x' }, run_id => $run->id },
          qr/needs a tenant and a run_id/ ],
    ) {
        my ( $name, $args, $why ) = @$case;
        my $info = run_job($args);
        is $info->{state}, 'failed', "$name: job failed";
        like $info->{result}, $why, "$name: refused before any schema was used";
    }
    is_deeply where( $adb, $run ), $parked, 'no step ran';
    ok $dao->db->query(q{SELECT 1 FROM pg_namespace WHERE nspname = 'registry'})->rows,
        'the registry schema is still there';
};

subtest 'completed run is a no-op' => sub {
    my $wf  = workflow( $adb, ['step-1'], [ 'step-2', undef, requiring( $adb, 'answer' ) ] );
    my $run = parked_run( $adb, $wf, { answer => 'yes' } );
    run_job( { tenant => $slug_a, run_id => $run->id } );
    ok reload( $adb, $run )->completed($adb), 'setup: the run is complete';

    # Re-processing the last step now would refuse it for want of its field.
    $adb->query( q{UPDATE workflow_runs SET data = data - 'answer' WHERE id = ?}, $run->id );
    my $done = where( $adb, $run );

    my $info = run_job( { tenant => $slug_a, run_id => $run->id } );

    is $info->{state}, 'finished', 'job finished';
    is_deeply $info->{result},
        { run_id => $run->id, stopped_at => 'step-2', reason => 'completed' },
        'reporting the run completed' or diag explain $info->{result};
    is_deeply where( $adb, $run ), $done, 'no step was re-processed';
};

subtest 'dying step leaves run parked at last persisted step' => sub {
    # The Payment step dies when asked to settle a run that names no payment.
    my $wf  = workflow( $adb, ['step-1'], ['step-2'],
        [ 'payment', 'Registry::DAO::WorkflowSteps::Payment' ], ['step-4'] );
    my $run = parked_run( $adb, $wf, { payment_intent_id => 'pi_cwr_none' } );

    my $info = run_job( { tenant => $slug_a, run_id => $run->id } );

    is $info->{state}, 'failed', 'job failed';
    like $info->{result}, qr/No payment_id in workflow data/, 'with the step\'s error';
    is reload( $adb, $run )->latest_step($adb)->slug, 'step-2',
        'the run is parked at the last persisted step; step 4 never ran';
};

done_testing;
