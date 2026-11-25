#!/usr/bin/env perl
# ABOUTME: A dispute Stripe reports lost on a tenant's account ends the entitlements its payment bought.
# ABOUTME: Signed Connect events, the entitlement-stripe-move workflow and its driver, against real Postgres.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::Offers qw( offer_terms );
use Test::Registry::StripeWebhook;
use Test::Registry::Helpers qw( import_all_workflows );
use Registry::DAO;
use Registry::DAO::Entitlement;
use Registry::DAO::Offer;
use Registry::DAO::Payment;
use Registry::DAO::Resource;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::DAO::WorkflowStep;
use Mojo::JSON ();
use POSIX ();

local $ENV{STRIPE_WEBHOOK_SECRET}         = 'whsec_local_platform_dispute_moves';
local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_local_connect_dispute_moves';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;
import_all_workflows($dao);

my $admin = Registry::DAO::User->create( $db, {
    username => "sdm_admin_$$", email => "sdm_admin_$$\@test.example", name => 'SDM Admin', user_type => 'admin' } );

# A tenant on its own connected account, provisioned with every workflow.
sub tenant ($name) {
    my $slug = "sdm_${name}_$$";
    Registry::DAO::Tenant->provision( $db, {
        name => "SDM $name $$", slug => $slug, users => [$admin], stripe_connect_account_id => "acct_$slug" } );
    return ( $slug, "acct_$slug", $dao->connect_schema($slug)->db );
}
my ( $A, $ACCOUNT_A, $adb ) = tenant('a');

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $dao } );
$t->app->log->unsubscribe('message');
my $minion = $t->app->minion;

my $made = 0;
sub person ( $tdb = $adb ) {
    return $tdb->insert( 'users', { username => 'sdm-p-' . ++$made }, { returning => 'id' } )->hash->{id};
}

# An occurrence four seats wide starting tomorrow, its own resource.
sub occurrence ( $tdb = $adb ) {
    my $class = $tdb->insert( 'projects', { name => 'Class ' . ++$made, slug => "sdm-class-$made" },
        { returning => 'id' } )->hash->{id};
    my $room = $tdb->insert( 'locations', { name => 'Room ' . ++$made, slug => "sdm-room-$made" },
        { returning => 'id' } )->hash->{id};
    my $event = $tdb->insert( 'events', {
        project_id => $class, location_id => $room, teacher_id => person($tdb),
        time       => \"now() + interval '24 hours'", duration => 90, capacity => 4,
    }, { returning => 'id' } )->hash->{id};
    return Registry::DAO::Resource->for_occurrence( $tdb, $event );
}

# A completed payment of $cents taken through Stripe intent $intent.
sub payment ( $cents, $intent, $tdb = $adb ) {
    return Registry::DAO::Payment->create( $tdb, {
        user_id => person($tdb), amount_cents => $cents, status => 'completed', stripe_payment_intent_id => $intent,
    } );
}

# An entitlement $payment bought for its whole amount, holding $seats seats of
# a new occurrence, held by $holder (a new person by default).
sub booking ( $payment, $seats = 1, $holder = undef ) {
    my $occurrence = occurrence();
    my $version = Registry::DAO::Offer->create( $adb, { name => 'Wheel ' . ++$made } )
        ->draft( $adb, offer_terms( $occurrence->id, units_per_acceptance => $seats, per_booking_cap => $seats ) )
        ->publish($adb);
    my ( undef, $ends ) = $occurrence->occurrence_window($adb);
    my $e = Registry::DAO::Entitlement->grant( $adb, {
        holder_user_id      => $holder // person(),
        offer_version_id    => $version->id,
        payment_plan_id     => 'pay',
        starts_at           => '2020-01-01T00:00:00Z',
        ends_at             => $ends,
        resource_id         => $occurrence->id,
        units               => $seats,
        payment_id          => $payment->id,
        payment_share_cents => $payment->amount_cents,
    } );
    return ( $e, $occurrence );
}

sub reread ($e) { Registry::DAO::Entitlement->find( $adb, { id => $e->id } ) }

# A charge.dispute.* event on $account disputing the charge behind $intent.
sub dispute ( $type, $account, $intent, $status, $id = "dp_$intent" ) {
    return { type => $type, account => $account, data => { object => {
        id => $id, object => 'dispute', amount => 2000, status => $status, reason => 'fraudulent',
        charge => "ch_for_$intent", payment_intent => $intent } } };
}

# Posts $event signed to the Connect endpoint and runs whatever it queued.
sub deliver ($event) {
    Test::Registry::StripeWebhook::post_connect( $t, {%$event} )->status_is(200);
    $minion->perform_jobs;
}

subtest 'lost dispute ends entitlement and frees seats' => sub {
    my $paid = payment( 2000, "pi_lost_$$" );
    my ( $e, $occurrence ) = booking( $paid, 2 );
    is $occurrence->free_units($adb), 2, 'the booking holds 2 of 4 seats';

    deliver( dispute( 'charge.dispute.closed', $ACCOUNT_A, "pi_lost_$$", 'lost' ) );

    my $after = reread($e);
    is $after->state,        'dispute_lost',  'a lost dispute ends the entitlement as dispute_lost';
    is $after->ended_reason, "dp_pi_lost_$$", 'naming the Stripe dispute';
    ok !$after->is_in_effect($adb), 'it is no longer in effect';
    is $occurrence->free_units($adb), 4, 'and its 2 seats are free';
};

sub count ( $table, $tdb = $adb ) { $tdb->query("SELECT count(*) FROM $table")->array->[0] }

sub processed_at ($event_id) {
    $db->query( 'SELECT processed_at FROM registry.webhook_events WHERE stripe_event_id = ?', $event_id )
        ->array->[0];
}

# A run of entitlement-stripe-move in $tdb for stored event $event_id, as the
# endpoint creates one.
sub move_run ( $event_id, $tdb = $adb ) {
    return Registry::DAO::Workflow->find( $tdb, { slug => 'entitlement-stripe-move' } )
        ->new_run( $tdb, { data => { stripe_event_id => $event_id } } );
}

sub drive ( $run, $slug = $A ) {
    my $id = $minion->enqueue( continue_workflow_run => [ { tenant => $slug, run_id => $run->id } ] );
    $minion->perform_jobs( { id => $id } );
    return $minion->job($id)->info;
}

# Nothing the moves could charge or refund through Stripe is queued.
sub stripe_jobs () { $minion->jobs( { tasks => [qw( superseded_refund instalment_schedule )] } )->total }

subtest 'open or won dispute leaves entitlement once per event' => sub {
    my $paid = payment( 2000, "pi_open_$$" );
    my ( $e, $occurrence ) = booking($paid);
    my ( $payments, $runs ) = ( count('payments'), count('workflow_runs') );

    my $opened = dispute( 'charge.dispute.created', $ACCOUNT_A, "pi_open_$$", 'needs_response' );
    $opened->{id} = "evt_open_$$";
    deliver($opened);
    is reread($e)->state, 'active', 'an opened dispute leaves it in effect';
    ok processed_at("evt_open_$$"), 'and its event is marked applied';

    deliver( dispute( 'charge.dispute.closed', $ACCOUNT_A, "pi_open_$$", 'won' ) );
    is reread($e)->state, 'active', 'a won dispute leaves it in effect';
    is $occurrence->free_units($adb), 3, 'holding its seat';
    is count('workflow_runs'), $runs + 2, 'one run per event';

    my $paid2 = payment( 2000, "pi_again_$$" );
    my ($lost) = booking($paid2);
    my $event = dispute( 'charge.dispute.closed', $ACCOUNT_A, "pi_again_$$", 'lost' );
    $event->{id} = "evt_again_$$";
    deliver($event);
    Test::Registry::StripeWebhook::post_connect( $t, {%$event} )->status_is(200)->content_is('OK (duplicate)');
    $minion->perform_jobs;
    is reread($lost)->state, 'dispute_lost', 'a lost dispute ends it';
    is count('workflow_runs'), $runs + 3, 'and its redelivery starts no second run';

    my $ended_at = reread($lost)->ended_at;
    is drive( move_run("evt_again_$$") )->{state}, 'finished', 'a retried run for the event finishes';
    is reread($lost)->ended_at, $ended_at, 'without ending it again';

    is count('payments'), $payments + 1, 'no payment is created by the moves (one was made here, by the test)';
    is stripe_jobs(), 0, 'and nothing is queued to charge through Stripe';
};

subtest 'non lost closure leaves entitlement' => sub {
    for my $status (qw( won warning_closed prevented under_review )) {
        my ( $e, $occurrence ) = booking( payment( 2000, "pi_${status}_$$" ) );
        deliver( dispute( 'charge.dispute.closed', $ACCOUNT_A, "pi_${status}_$$", $status ) );
        is reread($e)->state, 'active', "a dispute closed $status leaves it in effect";
        is $occurrence->free_units($adb), 3, 'holding its seat';
    }
    my ($e) = booking( payment( 2000, "pi_updated_$$" ) );
    deliver( dispute( 'charge.dispute.updated', $ACCOUNT_A, "pi_updated_$$", 'lost' ) );
    is reread($e)->state, 'active', 'only a closure ends it, not an update that says lost';
};

subtest 'unmatched dispute creates no run' => sub {
    my $runs = count('workflow_runs');
    my $event = dispute( 'charge.dispute.closed', $ACCOUNT_A, "pi_nowhere_$$", 'lost' );
    $event->{id} = "evt_nowhere_$$";
    deliver($event);
    is count('workflow_runs'), $runs, 'a dispute of a payment Registry did not make starts no run';
    ok !processed_at("evt_nowhere_$$"), 'and is left stored, unapplied';

    my $no_intent = dispute( 'charge.dispute.closed', $ACCOUNT_A, "pi_x_$$", 'lost' );
    delete $no_intent->{data}{object}{payment_intent};
    my ($e) = booking( payment( 2000, "pi_x_$$" ) );
    deliver($no_intent);
    is count('workflow_runs'), $runs, 'nor does one that names no payment intent';
    is reread($e)->state, 'active', 'and the entitlement stays in effect';
};

subtest 'cross account dispute changes nothing' => sub {
    my ( $B, $ACCOUNT_B, $bdb ) = tenant('b');
    my ( $e, $occurrence ) = booking( payment( 2000, "pi_cross_$$" ) );
    my ( $runs_a, $runs_b ) = ( count('workflow_runs'), count( 'workflow_runs', $bdb ) );

    my $event = dispute( 'charge.dispute.closed', $ACCOUNT_B, "pi_cross_$$", 'lost' );
    $event->{id} = "evt_cross_$$";
    deliver($event);
    is count( 'workflow_runs', $bdb ), $runs_b, 'tenant B has no payment with that intent, so no run';
    is count('workflow_runs'), $runs_a, 'and none starts in tenant A';

    is drive( move_run("evt_cross_$$") )->{state}, 'finished', "a run in A for B's stored event finishes";
    is reread($e)->state, 'active', "tenant A's entitlement stays in effect";
    is $occurrence->free_units($adb), 3, 'holding its seat';
    ok !processed_at("evt_cross_$$"), "and B's event is left unapplied";
};

subtest 'dispute after full refund keeps reason' => sub {
    my ( $e, $occurrence ) = booking( payment( 2000, "pi_refd_$$" ) );
    deliver( { type => 'refund.created', account => $ACCOUNT_A, data => { object => {
        id => "re_refd_$$", object => 'refund', amount => 2000, status => 'succeeded',
        payment_intent => "pi_refd_$$", charge => "ch_for_pi_refd_$$" } } } );
    is reread($e)->state, 'refunded', 'a full refund ends it first';
    my $ended_at = reread($e)->ended_at;

    my $event = dispute( 'charge.dispute.closed', $ACCOUNT_A, "pi_refd_$$", 'lost' );
    $event->{id} = "evt_refd_$$";
    deliver($event);
    my $after = reread($e);
    is $after->state,        'refunded',    'a later lost dispute leaves it refunded';
    is $after->ended_reason, "re_refd_$$",  'naming the refund';
    is $after->ended_at,     $ended_at,     'ended when the refund ended it';
    ok processed_at("evt_refd_$$"), 'and the dispute event is marked applied';
};

subtest 'dispute ends only charged entitlements' => sub {
    my $holder = person();
    my $cart   = payment( 4000, "pi_cart_$$" );
    my ($one)  = booking( $cart, 1, $holder );
    my ($two)  = booking( $cart, 1, $holder );
    my ( $other, $occurrence ) = booking( payment( 2000, "pi_other_$$" ), 1, $holder );

    deliver( dispute( 'charge.dispute.closed', $ACCOUNT_A, "pi_cart_$$", 'lost' ) );
    is reread($one)->state, 'dispute_lost', 'every entitlement the disputed charge bought ends';
    is reread($two)->state, 'dispute_lost', 'both of them';
    is reread($other)->state, 'active', "the same customer's entitlement on another payment does not";
    is $occurrence->free_units($adb), 3, 'and keeps its seat';
};

subtest 'dispute creates no payment or refund' => sub {
    my $paid = payment( 2000, "pi_nocharge_$$" );
    my ($e) = booking($paid);
    my $row = $adb->query( 'SELECT * FROM payments WHERE id = ?', $paid->id )->hash;
    my ( $payments, $refunds ) = ( count('payments'), count('entitlement_refunds') );

    deliver( dispute( 'charge.dispute.closed', $ACCOUNT_A, "pi_nocharge_$$", 'lost' ) );
    is reread($e)->state, 'dispute_lost', 'the lost dispute ends it';
    is count('payments'), $payments, 'no payment is created';
    is count('entitlement_refunds'), $refunds, 'no refund is recorded';
    is_deeply $adb->query( 'SELECT * FROM payments WHERE id = ?', $paid->id )->hash, $row,
        'the disputed payment is unchanged';
    is stripe_jobs(), 0, 'and no PaymentIntent or refund is queued with Stripe';
};

# Holds $first's transaction open in one connection while $second runs in a
# forked one; once $second waits on $first's locks, $first commits. Returns
# whether $second waited and what it returned.
sub race ( $first, $second ) {
    my $uri = $test_db->uri;
    pipe( my $parent_reads, my $child_writes ) or die "pipe: $!";
    my $hdb = Registry::DAO->new( url => $uri, schema => $A )->db;
    my $tx  = $hdb->begin;
    $first->($hdb);
    my $holder = $hdb->query('SELECT pg_backend_pid()')->array->[0];
    my $pid    = fork() // die "fork: $!";
    unless ($pid) {
        close $parent_reads;
        my $cdb = Registry::DAO->new( url => $uri, schema => $A )->db;
        my $out = eval { Mojo::JSON::to_json( $second->($cdb) ) } // Mojo::JSON::to_json( { died => "$@" } );
        print $child_writes $out;
        close $child_writes;
        POSIX::_exit(0);
    }
    close $child_writes;
    my ( $blocked, $deadline ) = ( 0, time + 30 );
    until ( $blocked || waitpid( $pid, POSIX::WNOHANG() ) || time > $deadline ) {
        select undef, undef, undef, 0.05;
        $blocked = $adb->query( 'SELECT count(*) FROM pg_stat_activity WHERE ? = ANY (pg_blocking_pids(pid))',
            $holder )->array->[0];
    }
    $tx->commit;
    waitpid $pid, 0;
    return ( $blocked, Mojo::JSON::from_json( do { local $/; readline $parent_reads } ) );
}

subtest 'concurrent duplicate dispute applied once' => sub {
    my ($e) = booking( payment( 2000, "pi_race_$$" ) );
    my $event = dispute( 'charge.dispute.closed', $ACCOUNT_A, "pi_race_$$", 'lost' );
    $event->{id} = "evt_race_$$";
    Test::Registry::StripeWebhook::post_connect( $t, {%$event} )->status_is(200);

    my @runs = map { move_run("evt_race_$$") } 1 .. 2;
    my sub apply ( $run, $h ) {
        my $r    = Registry::DAO::WorkflowRun->find( $h, { id => $run->id } );
        my $step = Registry::DAO::WorkflowStep->find( $h, { workflow_id => $r->workflow_id, slug => 'apply-dispute' } );
        return $step->process( $h, {}, $r );
    }
    my ( $blocked, $second ) = race( sub ($h) { apply( $runs[0], $h ) }, sub ($h) { apply( $runs[1], $h ) } );
    ok $blocked, 'the second application waited for the first';
    ok !$second->{died}, 'and then finished without error' or diag $second->{died};
    is reread($e)->state, 'dispute_lost', 'the entitlement is ended';
    ok processed_at("evt_race_$$"), 'and the event applied';
    my $ended_at = reread($e)->ended_at;
    $minion->perform_jobs;
    is reread($e)->ended_at, $ended_at, 'the queued run for it changes nothing';
};

done_testing;
