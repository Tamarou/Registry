# ABOUTME: Gated real-Stripe proof that a retried continue_workflow_run job moves money once: a driver that
# ABOUTME: died after Stripe answered and before the run advanced is retried to completion on the same charge.
# The charge's key is the Payment step's own pi-create:<token>, from the payment
# row it links to the run before calling Stripe, not a run:<id>:step:<slug> key
# the driver hands it: a re-run reuses the row and so the key, and a changed
# cart rotates the token, which a fixed run:step key could not do without Stripe
# refusing the new amount. The local half is t/job/continue-workflow-run-retry.t.
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
use Registry::DAO::Family;
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Session;
use Registry::DAO::PricingPlan;
use Registry::DAO::Payment;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;

plan skip_all => 'STRIPE_SECRET_KEY (sk_test_) not set'
    unless Test::Registry::StripeConnect::available();

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $slug  = "cwrr_live_$$";
my $admin = Registry::DAO::User->create( $db, {
    username => "cwrr_live_admin_$$", email => "cwrr_live_admin_$$\@test.example",
    name => 'CWRR Live Admin', user_type => 'admin' } );
Registry::DAO::Tenant->provision( $db, {
    name => "CWRR Live $$", slug => $slug, users => [$admin] } );
my $tdb = $dao->connect_schema($slug)->db;

note 'Waiting for charges_enabled on ready Stripe test account (up to 180s)...';
my $acct = Test::Registry::StripeConnect::ready_account();
like $acct, qr/^acct_/, 'ready account id obtained';
$db->query(
    'UPDATE registry.tenants SET stripe_connect_account_id = $1, stripe_charges_enabled = TRUE,
            stripe_details_submitted = TRUE WHERE slug = $2', $acct, $slug );
give_tenant_terms( $db, $slug, { rate => '0.025' } );

my $parent = Registry::DAO::User->create( $tdb, {
    username => "cwrr_live_parent_$$", email => "cwrr_live_parent_$$\@test.example",
    name => 'CWRR Live Parent', user_type => 'parent' } );

my $minion = Test::Registry::Mojo->new('Registry')->app->minion;

my $wf_n = 0;
# before -> the shipped Payment step -> after, in the tenant's schema.
sub payment_workflow () {
    $wf_n++;
    my $wf = Registry::DAO::Workflow->create( $tdb, {
        name => "CWRR Live $wf_n", slug => "cwrr-live-$wf_n-$$", description => 'retry test' } );
    $wf->add_step( $tdb, { slug => $_->[0], class => $_->[1] } ) for
        [ before  => 'Registry::DAO::WorkflowStep' ],
        [ payment => 'Registry::DAO::WorkflowSteps::Payment' ],
        [ after   => 'Registry::DAO::WorkflowStep' ];
    return $wf;
}

sub parked_run ( $wf, $data ) {
    my $run = $wf->new_run( $tdb, {} );
    $run->process( $tdb, $wf->first_step($tdb), { user_id => $parent->id, %$data } );
    return $run;
}

sub reload ($run) { Registry::DAO::WorkflowRun->find( $tdb, { id => $run->id } ) }

sub enqueue ($run) {
    $minion->enqueue( continue_workflow_run => [ { tenant => $slug, run_id => $run->id } ],
                      { attempts => 3 } );
}

subtest 'retried driver moves money once and completes run' => sub {
    # A real intent on the tenant's account, confirmed so Stripe holds it as
    # succeeded: the money has moved before the driver settles it.
    my $payment = Registry::DAO::Payment->create( $tdb, {
        user_id => $parent->id, amount_cents => 5000, metadata => { tenant_slug => $slug } } );
    settle( $payment->create_payment_intent_async( $tdb, { description => 'CWRR live' } ) );
    $payment = Registry::DAO::Payment->find( $tdb, { id => $payment->id } );
    my $intent = $payment->stripe_payment_intent_id;
    is Test::Registry::StripeConfirm::confirm( $intent, undef, $acct )->{status}, 'succeeded',
        'Stripe holds the intent as succeeded';

    my $run = parked_run( payment_workflow(),
        { payment_id => $payment->id, payment_intent_id => $intent } );

    # The first attempt dies after the payment step settled and before the run
    # advanced: Postgres refuses the advance while this trigger stands.
    $tdb->query( q{CREATE FUNCTION cwrr_die_before_advance() RETURNS trigger LANGUAGE plpgsql
                   AS $$ BEGIN RAISE EXCEPTION 'died before the run advanced'; END $$} );
    $tdb->query( q{CREATE TRIGGER cwrr_die_before_advance BEFORE UPDATE OF latest_step_id
                   ON workflow_runs FOR EACH ROW
                   WHEN (NEW.latest_step_id IS DISTINCT FROM OLD.latest_step_id)
                   EXECUTE FUNCTION cwrr_die_before_advance()} );
    my $id = enqueue($run);
    $minion->perform_jobs( { id => $id } );
    $tdb->query('DROP TRIGGER cwrr_die_before_advance ON workflow_runs');
    $tdb->query('DROP FUNCTION cwrr_die_before_advance()');

    like reload($run)->data->{__driver}{error}, qr/died before the run advanced/,
        'the first attempt died at the advance';
    is reload($run)->latest_step($tdb)->slug, 'before', 'and the run did not advance';
    is Registry::DAO::Payment->find( $tdb, { id => $payment->id } )->status, 'completed',
        'after the payment step had settled the charge';

    $minion->job($id)->retry;
    $minion->perform_jobs( { id => $id } );

    my $info = $minion->job($id)->info;
    is $info->{state}, 'finished', 'the retry finished' or diag explain $info->{result};
    is_deeply $info->{result},
        { run_id => $run->id, stopped_at => 'after', reason => 'completed' },
        'and completed the run';
    ok !defined reload($run)->data->{__driver}, 'which is no longer marked as failing';
    is $tdb->query( 'SELECT count(*) FROM payments WHERE stripe_payment_intent_id = ?', $intent )
           ->array->[0], 1, 'one payment row holds the charge';
    my $at_stripe = settle( Registry::DAO::Payment->find( $tdb, { id => $payment->id } )
        ->stripe_client->retrieve_payment_intent_async($intent) );
    is $at_stripe->{amount_received}, 5000, 'and Stripe received the money once';
};

subtest 'idempotency key stable across retries' => sub {
    # A priced cart the Payment step charges for itself.
    my $location = Registry::DAO::Location->create( $tdb, { time_zone => 'America/New_York',
        name => 'Loc', address_info => { street_address => '1 A', city => 'T', state => 'TS',
                                         postal_code => '12345' }, metadata => {} } );
    my $teacher = Registry::DAO::User->create( $tdb, {
        name => 'Teacher', username => "cwrr_live_t_$$", email => "cwrr_live_t_$$\@test.example",
        user_type => 'staff' } );
    my $project = Registry::DAO::Project->create( $tdb, { name => 'Paid Program', metadata => {} } );
    my $event   = Registry::DAO::Event->create( $tdb, {
        time => '2024-07-01 10:00:00', duration => 120, location_id => $location->id,
        project_id => $project->id, teacher_id => $teacher->id, metadata => {}, capacity => 20 } );
    my $session = Registry::DAO::Session->create( $tdb, {
        name => 'Paid Session', start_date => '2024-07-02', end_date => '2024-07-09',
        status => 'published', metadata => {} } );
    $session->add_events( $tdb, $event->id );
    Registry::DAO::PricingPlan->create( $tdb, {
        session_id => $session->id, plan_name => 'Paid', plan_type => 'standard',
        amount_cents => 5000 } );
    my $child = Registry::DAO::Family->add_child( $tdb, $parent->id, {
        child_name => 'Kid', birth_date => '2016-03-15', grade => '3', medical_info => {},
        emergency_contact => { name => 'E', phone => '555-0123' } } );

    my $run = parked_run( payment_workflow(), {
        children           => [ { id => $child->id } ],
        session_selections => { all => $session->id },
        enrollment_items   => [ { session_id => $session->id, child_id => $child->id } ],
        agreeTerms         => 1,
        __tenant_slug      => $slug,
    } );

    # The row, its key and the intent Stripe answered with, for this run.
    my $charges = sub {
        $tdb->query( q{SELECT id, metadata->>'idempotency_token' AS token, stripe_payment_intent_id
                         FROM payments WHERE metadata->>'workflow_run_id' = ?}, $run->id )
            ->hashes->to_array;
    };

    my @seen;
    for my $drive ( 1 .. 2 ) {
        my $id = enqueue($run);
        $minion->perform_jobs( { id => $id } );
        is_deeply $minion->job($id)->info->{result},
            { run_id => $run->id, stopped_at => 'payment', reason => 'needs_person' },
            "drive $drive reached Stripe and waits for the parent to confirm"
            or diag explain $minion->job($id)->info->{result};
        push @seen, $charges->();
    }

    is scalar @{ $seen[1] }, 1, 'the second drive reused the one payment row';
    like $seen[0][0]{stripe_payment_intent_id}, qr/^pi_/, 'the first drive got an intent';
    is_deeply $seen[1], $seen[0],
        'the same key, so Stripe answered the second call with the same intent';
};

done_testing;
