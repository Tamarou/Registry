# ABOUTME: Gated real-Stripe proof that the continue_workflow_run job awaits the shipped Payment step's
# ABOUTME: promise: a settled intent advances the run, a rejected settlement leaves it where it was parked.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::StripeConnect;
use Test::Registry::StripeConfirm;
use Test::Registry::DB;
use Test::Registry::PricingProbe qw( give_tenant_terms );
use Test::Registry::Mojo;
use Test::Registry::Async qw( settle );

use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Payment;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;

plan skip_all => 'STRIPE_SECRET_KEY (sk_test_) not set'
    unless Test::Registry::StripeConnect::available();

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $slug  = "cwr_live_$$";
my $admin = Registry::DAO::User->create( $db, {
    username => "cwr_live_admin_$$", email => "cwr_live_admin_$$\@test.example",
    name => 'CWR Live Admin', user_type => 'admin' } );
Registry::DAO::Tenant->provision( $db, {
    name => "CWR Live $$", slug => $slug, users => [$admin] } );
my $tdb = $dao->connect_schema($slug)->db;

note 'Waiting for charges_enabled on ready Stripe test account (up to 180s)...';
my $acct = Test::Registry::StripeConnect::ready_account();
like $acct, qr/^acct_/, 'ready account id obtained';
$db->query(
    'UPDATE registry.tenants SET stripe_connect_account_id = $1, stripe_charges_enabled = TRUE,
            stripe_details_submitted = TRUE WHERE slug = $2', $acct, $slug );
give_tenant_terms( $db, $slug, { rate => '0.025' } );

my $parent = Registry::DAO::User->create( $tdb, {
    username => "cwr_live_parent_$$", email => "cwr_live_parent_$$\@test.example",
    name => 'CWR Live Parent', user_type => 'parent' } );

my $minion = Test::Registry::Mojo->new('Registry')->app->minion;

my $wf_n = 0;
# before -> the shipped Payment step -> after, in the tenant's schema.
sub payment_workflow () {
    $wf_n++;
    my $wf = Registry::DAO::Workflow->create( $tdb, {
        name => "CWR Live $wf_n", slug => "cwr-live-$wf_n-$$", description => 'driver test' } );
    $wf->add_step( $tdb, { slug => $_->[0], class => $_->[1] } ) for
        [ before  => 'Registry::DAO::WorkflowStep' ],
        [ payment => 'Registry::DAO::WorkflowSteps::Payment' ],
        [ after   => 'Registry::DAO::WorkflowStep' ];
    return $wf;
}

# A payment row with a real intent on the tenant's account, confirmed so Stripe
# holds it as succeeded. %meta joins the row's metadata.
sub paid_intent (%meta) {
    my $payment = Registry::DAO::Payment->create( $tdb, {
        user_id      => $parent->id,
        amount_cents => 5000,
        metadata     => { tenant_slug => $slug, %meta },
    } );
    settle( $payment->create_payment_intent_async( $tdb, { description => 'CWR live' } ) );
    $payment = Registry::DAO::Payment->find( $tdb, { id => $payment->id } );
    my $intent = $payment->stripe_payment_intent_id;
    like $intent, qr/^pi_/, 'a real intent was created';
    is Test::Registry::StripeConfirm::confirm( $intent, undef, $acct )->{status}, 'succeeded',
        'and Stripe holds it as succeeded';
    return $payment;
}

# A run a person has taken past `before`, naming $payment for the Payment step
# to settle.
sub parked_run ( $wf, $payment ) {
    my $run = $wf->new_run( $tdb, {} );
    $run->process( $tdb, $wf->first_step($tdb), {
        user_id => $parent->id, payment_id => $payment->id,
        payment_intent_id => $payment->stripe_payment_intent_id } );
    return $run;
}

sub where ($run) {
    my $r = Registry::DAO::WorkflowRun->find( $tdb, { id => $run->id } );
    return { step => $r->latest_step($tdb)->slug, data => $r->data };
}

sub run_job ($args) {
    my $id = $minion->enqueue( continue_workflow_run => [$args] );
    $minion->perform_jobs( { id => $id } );
    return $minion->job($id)->info;
}

subtest 'a Payment step promise is awaited before the next step runs' => sub {
    my $payment = paid_intent();
    my $run     = parked_run( payment_workflow(), $payment );

    my $info = run_job( { tenant => $slug, run_id => $run->id } );

    is $info->{state}, 'finished', 'job finished' or diag explain $info->{result};
    is_deeply $info->{result},
        { run_id => $run->id, stopped_at => 'after', reason => 'completed' },
        'the run went on past the payment step to the end';
    is Registry::DAO::Payment->find( $tdb, { id => $payment->id } )->status, 'completed',
        'the payment step settled from what Stripe answered';
    is where($run)->{step}, 'after', 'the run is complete';
};

subtest 'rejected promise leaves run unchanged' => sub {
    # Stripe says succeeded, but settling dies on the cart the row snapshotted,
    # inside the settlement transaction: the step's promise rejects.
    my $payment = paid_intent(
        enrollment_items => [ { session_id => 'not-a-session', child_id => $parent->id } ] );
    my $run    = parked_run( payment_workflow(), $payment );
    my $parked = where($run);

    my $info = run_job( { tenant => $slug, run_id => $run->id } );

    is $info->{state}, 'failed', 'job failed';
    like $info->{result}, qr/invalid input syntax for type uuid/, 'with the rejection';
    my $now    = where($run);
    my $driver = delete $now->{data}{__driver};
    is_deeply $now, $parked, 'latest step and the rest of its data are unchanged';
    # The driver writes down each failed attempt; one attempt, so it is halted.
    is $driver->{step},  'payment', 'the run records the step that failed';
    is $driver->{state}, 'halted',  'and that its only attempt halted it';
    like $driver->{error}, qr/invalid input syntax for type uuid/, 'with the rejection';
    isnt Registry::DAO::Payment->find( $tdb, { id => $payment->id } )->status, 'completed',
        'the settlement was rolled back with it';
};

done_testing;
