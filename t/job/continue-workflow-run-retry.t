# ABOUTME: The continue_workflow_run job is safe to retry and to run twice at once: one driver per run,
# ABOUTME: each failure recorded on the run under __driver, and the last failed attempt marks it halted.
# The paid branch of the Payment step answers to Stripe, so moving money once on
# a retry is proven in t/stripe-live/continue-workflow-run-retry.t; here the
# shipped Payment step settles a $0 cart, which enrolls without the gateway.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Fork qw( forget_inherited_handles reap );
use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::PricingProbe qw( give_tenant_terms );
use Mojo::Pg;
use POSIX ();
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Family;
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Session;
use Registry::DAO::PricingPlan;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::DAO::OutcomeDefinition;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

my $admin = Registry::DAO::User->create( $dao->db, {
    username => "cwrr_admin_$$", email => "cwrr_admin_$$\@test.example",
    name => 'CWRR Admin', user_type => 'admin' } );

my $slug = "cwrr_$$";
Registry::DAO::Tenant->provision( $dao->db, {
    name => "CWRR $$", slug => $slug, users => [$admin] } );
my $adb = $dao->connect_schema($slug)->db;

my $t      = Test::Registry::Mojo->new('Registry');
my $minion = $t->app->minion;

# A $0 session a child can be enrolled in without the gateway.
my $location = Registry::DAO::Location->create( $adb, { time_zone => 'America/New_York',
    name => 'Loc', address_info => { street_address => '1 A', city => 'T', state => 'TS',
                                     postal_code => '12345' }, metadata => {} } );
my $teacher = Registry::DAO::User->create( $adb, {
    name => 'Teacher', username => "cwrr_t_$$", email => "cwrr_t_$$\@test.example",
    user_type => 'staff' } );
my $project = Registry::DAO::Project->create( $adb, { name => 'Free Program', metadata => {} } );
my $event   = Registry::DAO::Event->create( $adb, {
    time => '2024-07-01 10:00:00', duration => 120, location_id => $location->id,
    project_id => $project->id, teacher_id => $teacher->id, metadata => {}, capacity => 20 } );
my $session = Registry::DAO::Session->create( $adb, {
    name => 'Free Session', start_date => '2024-07-02', end_date => '2024-07-09',
    status => 'published', metadata => {} } );
$session->add_events( $adb, $event->id );
Registry::DAO::PricingPlan->create( $adb, {
    session_id => $session->id, plan_name => 'Free', plan_type => 'standard', amount_cents => 0 } );
my $parent = Registry::DAO::User->create( $adb, {
    username => "cwrr_p_$$", email => "cwrr_p_$$\@test.example", name => 'Parent',
    user_type => 'parent' } );
my $child = Registry::DAO::Family->add_child( $adb, $parent->id, {
    child_name => 'Kid', birth_date => '2016-03-15', grade => '3', medical_info => {},
    emergency_contact => { name => 'E', phone => '555-0123' } } );

# What the Payment step settles a $0 cart from.
my %free_cart = (
    user_id            => $parent->id,
    children           => [ { id => $child->id } ],
    session_selections => { all => $session->id },
    enrollment_items   => [ { session_id => $session->id, child_id => $child->id } ],
    agreeTerms         => 1,
);

sub requiring ( $db, $field ) {
    Registry::DAO::OutcomeDefinition->create( $db, {
        name   => "needs $field $$ " . rand,
        schema => { fields => [ { id => $field, type => 'text', required => 1 } ] },
    } )->id;
}

# step-1 -> step-2 (needs only_once) -> the shipped Payment step -> step-4.
my $wf_n = 0;
sub payment_workflow ($db = $adb) {
    $wf_n++;
    my $wf = Registry::DAO::Workflow->create( $db, {
        name => "CWRR $wf_n", slug => "cwrr-$wf_n-$$", description => 'retry test' } );
    $wf->add_step( $db, { slug => 'step-1', class => 'Registry::DAO::WorkflowStep' } );
    $wf->add_step( $db, { slug => 'step-2', class => 'Registry::DAO::WorkflowStep',
                          outcome_definition_id => requiring( $db, 'only_once' ) } );
    $wf->add_step( $db, { slug => 'payment', class => 'Registry::DAO::WorkflowSteps::Payment' } );
    $wf->add_step( $db, { slug => 'step-4', class => 'Registry::DAO::WorkflowStep' } );
    return $wf;
}

sub parked_run ( $wf, $data ) {
    my $run = $wf->new_run( $adb, {} );
    $run->process( $adb, $wf->first_step($adb), { only_once => 1, %$data } );
    return $run;
}

sub reload ($run) { Registry::DAO::WorkflowRun->find( $adb, { id => $run->id } ) }
sub at ($run)     { reload($run)->latest_step($adb)->slug }

sub enrollments () {
    $adb->query( 'SELECT count(*) FROM enrollments WHERE family_member_id = ?', $child->id )
        ->array->[0];
}

sub enqueue ($run) {
    $minion->enqueue( continue_workflow_run => [ { tenant => $slug, run_id => $run->id } ],
                      { attempts => 3 } );
}

# Performs a job and each of its retries straight away, not after Minion's backoff.
sub retry_at_once ($id) {
    my $backoff = $minion->backoff;
    $minion->backoff( sub ($retries) {0} );
    $minion->perform_jobs( { id => $id } );
    $minion->backoff($backoff);
}

# The Payment step dies settling a callback for a run that names no payment.
my %dies_at_payment = ( payment_intent_id => 'pi_cwrr_none' );

subtest 'non-final failure does not halt run' => sub {
    my $run = parked_run( payment_workflow(), \%dies_at_payment );
    my $id  = enqueue($run);

    $minion->perform_jobs( { id => $id } );    # the default backoff delays the retry

    my $info = $minion->job($id)->info;
    is $info->{retries}, 1, 'the failed first attempt is queued for a retry';
    my $driver = reload($run)->data->{__driver};
    is $driver->{step}, 'payment', 'the failure names the failing step';
    is $driver->{attempt}, 1, 'and the attempt';
    like $driver->{error}, qr/No payment_id in workflow data/, 'and the error';
    ok $driver->{at}, 'and when';
    ok !exists $driver->{state}, 'but the run is not halted';
    is at($run), 'step-2', 'the run is parked at the last persisted step';
};

subtest 'exhausted attempts mark run halted' => sub {
    my $run = parked_run( payment_workflow(), \%dies_at_payment );
    my $id  = enqueue($run);

    retry_at_once($id);

    my $info = $minion->job($id)->info;
    is $info->{state}, 'failed', 'the job failed';
    is $info->{retries}, 2, 'on its third attempt';
    my $driver = reload($run)->data->{__driver};
    is $driver->{state}, 'halted', 'the run is marked halted';
    is $driver->{step}, 'payment', 'at the failing step';
    is $driver->{attempt}, 3, 'on the last attempt';
    like $driver->{error}, qr/No payment_id in workflow data/, 'with its error';
    is at($run), 'step-2', 'latest_step_id is unchanged';
};

sub halt_alerts ($run) {
    $adb->query( q{SELECT count(*) FROM notifications WHERE metadata->>'workflow_run_id' = ?}, $run->id )
        ->array->[0];
}

subtest 'halted run alerts tenant admins' => sub {
    my $retried = parked_run( payment_workflow(), \%dies_at_payment );
    $minion->perform_jobs( { id => enqueue($retried) } );
    is halt_alerts($retried), 0, 'a failed attempt with retries left alerts nobody';

    my $run = parked_run( payment_workflow(), \%dies_at_payment );
    retry_at_once( enqueue($run) );
    is reload($run)->data->{__driver}{state}, 'halted', 'the last attempt halts the run';
    ok halt_alerts($run) >= 1, "and alerts the tenant's admins";
    my $note = $adb->query( q{SELECT subject, message FROM notifications WHERE metadata->>'workflow_run_id' = ?},
        $run->id )->hash;
    like $note->{message}, qr/\Q@{[ $run->id ]}\E.*payment|payment.*\Q@{[ $run->id ]}\E/s,
        'naming the run and the step it halted at';
};

subtest 'job arguments cannot turn the halt alert off' => sub {
    my $run = parked_run( payment_workflow(), \%dies_at_payment );
    retry_at_once( $minion->enqueue( continue_workflow_run =>
        [ { tenant => $slug, run_id => $run->id }, alert_admins => 0 ], { attempts => 3 } ) );
    is reload($run)->data->{__driver}{state}, 'halted', 'the last attempt halts the run';
    ok halt_alerts($run) >= 1, "and still alerts the tenant's admins";
};

subtest 'halted run resumes at halted step' => sub {
    my $run = parked_run( payment_workflow(), \%dies_at_payment );
    my $id  = enqueue($run);
    retry_at_once($id);
    is reload($run)->data->{__driver}{state}, 'halted', 'setup: the run is halted';

    # An admin fixes what the step died on. Step 2 would now refuse to run again.
    $adb->query( q{UPDATE workflow_runs SET data = data - 'only_once' - 'payment_intent_id'
                                                 || ?::jsonb WHERE id = ?},
                 Mojo::JSON::encode_json( { %free_cart, enrollment_items => [] } ), $run->id );

    my $again = enqueue($run);
    $minion->perform_jobs( { id => $again } );

    my $info = $minion->job($again)->info;
    is_deeply $info->{result},
        { run_id => $run->id, stopped_at => 'step-4', reason => 'completed' },
        'the run went on from the payment step to its end, not back through step 2'
        or diag explain $info->{result};
    ok !defined reload($run)->data->{__driver}, 'and is no longer marked halted';
};

# --- two drivers at once -------------------------------------------------------

my $watch = Mojo::Pg->new( $test_db->uri )->db;

# The backends waiting on a lock, with who they wait on. Polled, not slept on.
sub waiting_until ( $want, $why ) {
    for ( 1 .. 1000 ) {
        my $rows = $watch->query( q{
            SELECT pid, wait_event, pg_blocking_pids(pid) AS blockers FROM pg_stat_activity
             WHERE cardinality(pg_blocking_pids(pid)) > 0 ORDER BY pid } )->hashes->to_array;
        return $rows if $want->($rows);
        $watch->query('SELECT pg_sleep(0.01)');
    }
    die "timed out waiting for $why\n";
}

sub perform_in_child ($id) {
    my $pid = fork // die "fork: $!";
    return $pid if $pid;
    forget_inherited_handles();
    $minion->perform_jobs( { id => $id } );
    POSIX::_exit(0);
}

subtest 'concurrent drivers move money once' => sub {
    my $run    = parked_run( payment_workflow(), \%free_cart );
    my $before = enrollments();
    my ( $j1, $j2 ) = ( enqueue($run), enqueue($run) );

    # Hold the run's row so the first driver stops inside the payment step.
    my $tx = $adb->begin;
    $adb->query( 'SELECT 1 FROM workflow_runs WHERE id = ? FOR UPDATE', $run->id );
    my $me = $adb->pid;

    my $c1    = perform_in_child($j1);
    my ($one) = map { $_->{pid} }
        @{ waiting_until( sub ($r) { @$r == 1 }, 'the first driver to reach the run row' ) };

    my $c2   = perform_in_child($j2);
    my $rows = waiting_until( sub ($r) { @$r == 2 }, 'the second driver to wait' );
    my ($two) = grep { $_->{pid} != $one } @$rows;
    is_deeply [ $two->@{qw(wait_event blockers)} ], [ 'advisory', [$one] ],
        'the second driver waits on the first for the run, not inside a step of its own';

    $tx->commit;
    reap($_) for $c1, $c2;

    is $minion->job($_)->info->{state}, 'finished', "job $_ finished"
        or diag explain $minion->job($_)->info->{result} for $j1, $j2;
    is enrollments() - $before, 1, 'the payment step settled once';
    is at($run), 'step-4', 'and the run completed';
};

subtest 'retried $0 settlement enrols once' => sub {
    # A driver that died after the settlement and before the advance runs the
    # payment step again on the same run.
    my $kid = Registry::DAO::Family->add_child( $adb, $parent->id, {
        child_name => 'Second Kid', birth_date => '2017-03-15', grade => '2', medical_info => {},
        emergency_contact => { name => 'E', phone => '555-0123' } } );
    my %cart = ( %free_cart, children => [ { id => $kid->id } ],
                 enrollment_items => [ { session_id => $session->id, child_id => $kid->id } ] );
    my $wf   = payment_workflow();
    my $run  = parked_run( $wf, \%cart );
    my $step = Registry::DAO::WorkflowStep->find( $adb, { workflow_id => $wf->id, slug => 'payment' } );

    my $ok = eval { $step->process( $adb, \%cart, $run ) for 1 .. 2; 1 };

    ok $ok, 'the second settlement succeeds' or diag $@;
    is $adb->query( q{SELECT count(*) FROM enrollments WHERE family_member_id = ?
                         AND session_id = ? AND status = 'active'}, $kid->id, $session->id )
           ->array->[0], 1, 'and the child holds one enrollment';
};

# --- the charge's idempotency key -------------------------------------------------
#
# A money-moving step keys its Stripe call on state it saved before the call,
# not on a run:<id>:step:<slug> key the driver would hand it: the Payment step
# links its payment row to the run before creating the intent, and keys the
# intent on that row's token (pi-create:<token>). A re-run of the step reuses
# the row and so the key; a cart whose amount changed rotates the token, which
# a fixed run:step key could not do without Stripe refusing the new amount.
# Stripe is never reached with a usable key here: the call fails and the step
# waits for a person, after the row and its token are written. A refused call
# marks the row failed, so a re-run here mints a new row; that the key holds
# across a re-run after Stripe ANSWERED, and the money moves once, is proven
# against real Stripe in t/stripe-live/continue-workflow-run-retry.t.

my $priced = Registry::DAO::Session->create( $adb, {
    name => 'Paid Session', start_date => '2024-07-02', end_date => '2024-07-09',
    status => 'published', metadata => {} } );
$priced->add_events( $adb, $event->id );
Registry::DAO::PricingPlan->create( $adb, {
    session_id => $priced->id, plan_name => 'Paid', plan_type => 'standard', amount_cents => 5000 } );
$dao->db->query( q{UPDATE registry.tenants SET stripe_connect_account_id = 'acct_cwrrlocal',
                   stripe_charges_enabled = TRUE, stripe_details_submitted = TRUE WHERE slug = ?},
                 $slug );
give_tenant_terms( $dao->db, $slug, { rate => '0.025' } );

my %paid_cart = (
    %free_cart,
    session_selections => { all => $priced->id },
    enrollment_items   => [ { session_id => $priced->id, child_id => $child->id } ],
    __tenant_slug      => $slug,
);

# The keys of the charges a run's payment rows would send, read from the database.
sub charge_keys ($run) {
    $adb->query( q{SELECT 'pi-create:' || (metadata->>'idempotency_token') FROM payments
                    WHERE metadata->>'workflow_run_id' = ? ORDER BY created_at},
                 $run->id )->arrays->map( sub { $_->[0] } )->to_array;
}

sub drive ($run) {
    my $id = enqueue($run);
    $minion->perform_jobs( { id => $id } );
    return $minion->job($id)->info;
}

subtest 'idempotency key differs between runs' => sub {
    my $wf = payment_workflow();
    my ( $one, $two ) = map { parked_run( $wf, \%paid_cart ) } 1 .. 2;
    drive($_) for $one, $two;

    my ( $k1, $k2 ) = map { charge_keys($_)->[0] } $one, $two;
    like $k1, qr/\Api-create:[0-9a-f-]{36}\z/, 'the first run\'s charge has a key';
    like $k2, qr/\Api-create:[0-9a-f-]{36}\z/, 'and so does the second\'s';
    isnt $k1, $k2, 'at the same step slug, the two runs\' keys differ';
};

# --- the client cannot write __driver -------------------------------------------

subtest 'client driver key is stripped' => sub {
    my $rdb = $dao->db;
    my $wf  = Registry::DAO::Workflow->create( $rdb, {
        name => 'Driver key', slug => "driver-key-$$", description => 'passthrough', public => 1 } );
    $wf->add_step( $rdb, { slug => 'landing',  class => 'Registry::DAO::WorkflowStep' } );
    $wf->add_step( $rdb, { slug => 'complete', class => 'Registry::DAO::WorkflowStep' } );

    my %planted = ( __driver => 'x', '__driver[state]' => 'halted', kept => 'yes' );

    $t->post_ok( "/driver-key-$$" => form => \%planted )->status_is(302);
    my ($run_id) = $t->tx->res->headers->location =~ m{/driver-key-$$/([^/]+)/};
    my $data = Registry::DAO::WorkflowRun->find( $rdb, { id => $run_id } )->data;
    ok !exists $data->{__driver}, 'not on the first step';
    is $data->{kept}, 'yes', 'while the rest of the form is kept';

    $t->post_ok( "/driver-key-$$/$run_id/complete" => form => \%planted )->status_is(201);
    $data = Registry::DAO::WorkflowRun->find( $rdb, { id => $run_id } )->data;
    ok !exists $data->{__driver}, 'nor on a later step';
};

done_testing;
