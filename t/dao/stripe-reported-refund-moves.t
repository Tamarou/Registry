#!/usr/bin/env perl
# ABOUTME: Refunds Stripe reports on a tenant's account are applied to the entitlements their payment bought.
# ABOUTME: Signed Connect events, the entitlement-stripe-move workflow and its driver, against real Postgres.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Fork qw( forget_inherited_handles reap );
use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::Offers qw( offer_terms );
use Test::Registry::StripeWebhook;
use Test::Registry::Helpers qw( authenticate_as import_all_workflows join_tenant );
use Test::Registry::SoloVersion qw(accept_solo);
use Test::Registry::Fixtures;
use Registry::DAO;
use Registry::DAO::Entitlement;
use Registry::DAO::Offer;
use Registry::DAO::Payment;
use Registry::DAO::Resource;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Mojo::JSON ();
use POSIX ();

local $ENV{STRIPE_WEBHOOK_SECRET}         = 'whsec_local_platform_refund_moves';
local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_local_connect_refund_moves';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;
import_all_workflows($dao);

my $admin = Registry::DAO::User->create( $db, {
    username => "srm_admin_$$", email => "srm_admin_$$\@test.example", name => 'SRM Admin', user_type => 'admin' } );

# A tenant on its own connected account, holding Solo's workflows.
sub tenant ($name) {
    my $slug = "srm_${name}_$$";
    accept_solo( $db, Registry::DAO::Tenant->provision( $db, {
        name => "SRM $name $$", slug => $slug, users => [$admin], stripe_connect_account_id => "acct_$slug" } ) );
    return ( $slug, "acct_$slug", $dao->connect_schema($slug)->db );
}
my ( $A, $ACCOUNT_A, $adb ) = tenant('a');

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $dao } );
$t->app->log->unsubscribe('message');
my $minion = $t->app->minion;

my $made = 0;
sub person ( $tdb = $adb ) {
    return $tdb->insert( 'users', { username => 'srm-p-' . ++$made }, { returning => 'id' } )->hash->{id};
}

# An occurrence four seats wide starting tomorrow, its own resource.
sub occurrence ( $tdb = $adb ) {
    my $class = $tdb->insert( 'projects', { name => 'Class ' . ++$made, slug => "srm-class-$made" },
        { returning => 'id' } )->hash->{id};
    my $room = $tdb->insert( 'locations', { time_zone => 'America/New_York', name => 'Room ' . ++$made, slug => "srm-room-$made" },
        { returning => 'id' } )->hash->{id};
    my $event = $tdb->insert( 'events', {
        project_id => $class, location_id => $room, teacher_id => person($tdb),
        time       => \"now() + interval '24 hours'", duration => 90, capacity => 4,
    }, { returning => 'id' } )->hash->{id};
    return Registry::DAO::Resource->for_occurrence( $tdb, $event );
}

# A completed payment of $cents taken through Stripe intent $intent.
sub payment ( $cents, $intent, $tdb = $adb, %meta ) {
    return Registry::DAO::Payment->create( $tdb, {
        user_id => person($tdb), amount_cents => $cents, status => 'completed',
        stripe_payment_intent_id => $intent, metadata => {%meta},
    } );
}

# An entitlement $payment bought for $share cents, holding $seats seats of
# $occurrence (a new one by default), sold under refund policy none.
sub booking ( $payment, $share, $seats = 1, $occurrence = undef, $tdb = $adb ) {
    $occurrence //= occurrence($tdb);
    my $version = Registry::DAO::Offer->create( $tdb, { name => 'Wheel ' . ++$made } )
        ->draft( $tdb, offer_terms( $occurrence->id, units_per_acceptance => $seats, per_booking_cap => $seats ) )
        ->publish($tdb);
    my ( undef, $ends ) = $occurrence->occurrence_window($tdb);
    my $e = Registry::DAO::Entitlement->grant( $tdb, {
        holder_user_id      => person($tdb),
        offer_version_id    => $version->id,
        payment_plan_id     => 'pay',
        starts_at           => '2020-01-01T00:00:00Z',
        ends_at             => $ends,
        resource_id         => $occurrence->id,
        units               => $seats,
        payment_id          => $payment->id,
        payment_share_cents => $share,
    } );
    return ( $e, $occurrence );
}

sub reread ( $e, $tdb = $adb ) { Registry::DAO::Entitlement->find( $tdb, { id => $e->id } ) }

# A Stripe refund object.
sub refund ( $id, $intent, $cents, $status = 'succeeded' ) {
    return { id => $id, object => 'refund', amount => $cents, status => $status, payment_intent => $intent,
             charge => "ch_for_$intent" };
}

# charge.refunded on $account for the charge behind $intent, listing @refunds.
sub charge_refunded ( $account, $intent, @refunds ) {
    my $refunded = 0;
    $refunded += $_->{amount} for @refunds;
    return { type => 'charge.refunded', account => $account, data => { object => {
        id => "ch_for_$intent", object => 'charge', payment_intent => $intent,
        amount_refunded => $refunded, refunds => { object => 'list', data => [@refunds] } } } };
}

# A refund.* event on $account carrying the one refund object.
sub refund_event ( $type, $account, $refund ) {
    return { type => $type, account => $account, data => { object => $refund } };
}

# Posts $event signed to the Connect endpoint and runs whatever it queued.
sub deliver ($event) {
    Test::Registry::StripeWebhook::post_connect( $t, {%$event} )->status_is(200);
    $minion->perform_jobs;
}

subtest 'full refund ends entitlement partial refund recorded' => sub {
    my $paid = payment( 4000, "pi_full_$$" );
    my ( $e, $occurrence ) = booking( $paid, 4000, 2 );
    is $occurrence->free_units($adb), 2, 'the booking holds 2 of 4 seats';

    deliver( charge_refunded( $ACCOUNT_A, "pi_full_$$", refund( "re_full_$$", "pi_full_$$", 4000 ) ) );

    my $after = reread($e);
    is $after->state,        'refunded',  'a full refund ends the entitlement as refunded';
    is $after->ended_reason, "re_full_$$", 'naming the Stripe refund';
    is $occurrence->free_units($adb), 4, 'and its 2 seats are free';
    is $after->refunded_cents($adb), 4000, 'the refund is recorded against it';

    my $part = payment( 4000, "pi_part_$$" );
    my ( $p, $seats ) = booking( $part, 4000, 2 );
    deliver( refund_event( 'refund.created', $ACCOUNT_A, refund( "re_part1_$$", "pi_part_$$", 1500 ) ) );
    is reread($p)->state, 'active', 'a partial refund leaves it in effect';
    is $seats->free_units($adb), 2, 'holding its seats';
    is_deeply $adb->query( 'SELECT amount_cents, stripe_refund_id FROM entitlement_refunds WHERE entitlement_id = ?',
        $p->id )->hashes->to_array, [ { amount_cents => 1500, stripe_refund_id => "re_part1_$$" } ],
        'and is recorded with its amount and Stripe refund id';

    deliver( refund_event( 'refund.created', $ACCOUNT_A, refund( "re_part2_$$", "pi_part_$$", 2500 ) ) );
    is reread($p)->state,        'refunded',   'a later refund that makes it full ends it';
    is reread($p)->ended_reason, "re_part2_$$", 'naming that refund';
    is $p->refunded_cents($adb), 4000, 'the two refunds sum with no double count';
    is $seats->free_units($adb), 4, 'and its seats are free';
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

subtest 'stripe refunds apply regardless of policy once' => sub {
    my $paid = payment( 3000, "pi_once_$$" );
    my ( $e, $occurrence ) = booking( $paid, 3000, 1 );
    is $e->offer_version($adb)->policies->{refund}{kind}, 'none', 'sold under refund policy none';
    my ( $payments, $runs ) = ( count('payments'), count('workflow_runs') );

    my $event = refund_event( 'refund.created', $ACCOUNT_A, refund( "re_once_$$", "pi_once_$$", 3000 ) );
    $event->{id} = "evt_once_$$";
    deliver($event);
    Test::Registry::StripeWebhook::post_connect( $t, {%$event} )->status_is(200)->content_is('OK (duplicate)');
    $minion->perform_jobs;

    is reread($e)->state, 'refunded', 'the Stripe refund ends it despite the policy';
    ok processed_at("evt_once_$$"), 'the stored event is marked applied';
    is count('workflow_runs'), $runs + 1, 'the redelivery starts no second run';

    is drive( move_run("evt_once_$$") )->{state}, 'finished', 'a retried run for the event finishes';
    deliver( charge_refunded( $ACCOUNT_A, "pi_once_$$", refund( "re_once_$$", "pi_once_$$", 3000 ) ) );
    is $e->refunded_cents($adb), 3000, 'the refund is applied once, however often it is reported';
    is $adb->query( 'SELECT count(*) FROM entitlement_refunds WHERE entitlement_id = ?', $e->id )->array->[0], 1,
        'with one record';
    is reread($e)->ended_reason, "re_once_$$", 'and the entitlement keeps how it ended';

    my $part = payment( 3000, "pi_once_part_$$" );
    my ($p) = booking( $part, 3000, 1 );
    my $partial = refund_event( 'refund.created', $ACCOUNT_A, refund( "re_once_part_$$", "pi_once_part_$$", 1000 ) );
    $partial->{id} = "evt_once_part_$$";
    deliver($partial);
    is drive( move_run("evt_once_part_$$") )->{state}, 'finished', 'a retried run for the partial refund finishes';
    deliver( charge_refunded( $ACCOUNT_A, "pi_once_part_$$", refund( "re_once_part_$$", "pi_once_part_$$", 1000 ) ) );
    is $p->refunded_cents($adb), 1000, 'a partial refund reported again and retried counts once';
    is reread($p)->state, 'active', 'and leaves it in effect';

    is count('payments'), $payments + 1, 'no payment is created by the moves (one was made here, by the test)';
    is $minion->jobs( { tasks => [qw( superseded_refund instalment_schedule )] } )->total, 0,
        'and nothing is queued to charge or refund through Stripe';
};

subtest 'entitlement-stripe-move admits admin and refuses staff' => sub {
    my sub a_user ( $name, $role ) {
        my $user = Test::Registry::Fixtures::create_user( $dao,
            { username => "${name}_$$", name => $name, email => "${name}_$$\@srm.test", user_type => $role } );
        join_tenant( $dao, $user, $role, 'registry' );
        my $client = Test::Registry::Mojo->new('Registry');
        authenticate_as( $client, $user );
        return $client;
    }
    my sub runs () {
        $db->query( q{SELECT count(*) FROM workflow_runs r JOIN workflows w ON w.id = r.workflow_id
                       WHERE w.slug = 'entitlement-stripe-move'} )->array->[0];
    }
    a_user( 'srm_gate_admin', 'admin' )->get_ok('/entitlement-stripe-move')->status_is(200);
    my $before = runs();
    a_user( 'srm_gate_staff', 'staff' )->get_ok('/entitlement-stripe-move')->status_is(403);
    is runs(), $before, 'no run is created for staff';
};

sub records ($e) {
    $adb->query( 'SELECT amount_cents FROM entitlement_refunds WHERE entitlement_id = ? ORDER BY recorded_at',
        $e->id )->arrays->flatten->to_array;
}

subtest 'unmatched refund creates no run' => sub {
    my $runs = count('workflow_runs');
    deliver( refund_event( 'refund.created', $ACCOUNT_A, refund( "re_nowhere_$$", "pi_nowhere_$$", 2000 ) ) );
    is count('workflow_runs'), $runs, 'a refund of a payment Registry did not make starts no run';

    # The refund Registry sends for a paid superseded intent comes back as a
    # refund of that intent, which is not the one the payment kept.
    my $kept = payment( 2000, "pi_kept_$$", $adb, superseded_intent_ids => ["pi_superseded_$$"] );
    my ($e) = booking( $kept, 2000 );
    my $row = $adb->query( 'SELECT * FROM payments WHERE id = ?', $kept->id )->hash;
    deliver( charge_refunded( $ACCOUNT_A, "pi_superseded_$$", refund( "re_superseded_$$", "pi_superseded_$$", 2000 ) ) );
    is count('workflow_runs'), $runs, 'nor does the refund of a superseded intent';
    is reread($e)->state, 'active', 'which leaves the entitlement in effect';
    is_deeply records($e), [], 'with nothing recorded against it';
    is_deeply $adb->query( 'SELECT * FROM payments WHERE id = ?', $kept->id )->hash, $row,
        "and the payment's status and refunded total unchanged";
};

subtest 'cross account refund changes nothing' => sub {
    my ( $B, $ACCOUNT_B, $bdb ) = tenant('b');
    my $paid = payment( 2000, "pi_cross_$$" );
    my ( $e, $occurrence ) = booking( $paid, 2000 );
    my ( $runs_a, $runs_b ) = ( count('workflow_runs'), count( 'workflow_runs', $bdb ) );

    my $event = refund_event( 'refund.created', $ACCOUNT_B, refund( "re_cross_$$", "pi_cross_$$", 2000 ) );
    $event->{id} = "evt_cross_$$";
    deliver($event);
    is count( 'workflow_runs', $bdb ), $runs_b, "tenant B has no payment with that intent, so no run";
    is count('workflow_runs'), $runs_a, 'and none starts in tenant A';

    is drive( move_run("evt_cross_$$") )->{state}, 'finished', "a run in A for B's stored event finishes";
    is reread($e)->state, 'active', "tenant A's entitlement stays in effect";
    is_deeply records($e), [], 'with nothing recorded';
    is $occurrence->free_units($adb), 3, 'holding its seat';
    ok !processed_at("evt_cross_$$"), "and B's event is left unapplied";
};

subtest 'pending or failed refund does not end' => sub {
    my $paid = payment( 2000, "pi_pend_$$" );
    my ($e) = booking( $paid, 2000 );

    deliver( refund_event( 'refund.created', $ACCOUNT_A, refund( "re_pend_$$", "pi_pend_$$", 2000, 'pending' ) ) );
    is reread($e)->state, 'active', 'a pending refund leaves it in effect';
    is_deeply records($e), [], 'and records nothing';

    deliver( refund_event( 'refund.updated', $ACCOUNT_A, refund( "re_pend_$$", "pi_pend_$$", 2000, 'failed' ) ) );
    is reread($e)->state, 'active', 'a failed refund leaves it in effect';
    is_deeply records($e), [], 'and records nothing';

    deliver( refund_event( 'refund.updated', $ACCOUNT_A, refund( "re_pend2_$$", "pi_pend_$$", 2000, 'pending' ) ) );
    deliver( refund_event( 'refund.updated', $ACCOUNT_A, refund( "re_pend2_$$", "pi_pend_$$", 2000 ) ) );
    is reread($e)->state, 'refunded', 'a pending refund that then succeeds ends it';
};

subtest 'partial refund across two entitlements follows allocation' => sub {
    my $cart = payment( 6000, "pi_cart_$$" );
    my ($one) = booking( $cart, 2000, 1 );
    my ($two) = booking( $cart, 4000, 2 );

    deliver( refund_event( 'refund.created', $ACCOUNT_A, refund( "re_cart1_$$", "pi_cart_$$", 2000 ) ) );
    is_deeply [ records($one), records($two) ], [ [667], [1333] ],
        "shared in proportion to each one's unrefunded share, the leftover cent to the larger remainder";
    is reread($one)->state, 'active', 'a refund the size of one share does not end the first';
    is reread($two)->state, 'active', 'nor the second';

    deliver( refund_event( 'refund.created', $ACCOUNT_A, refund( "re_cart2_$$", "pi_cart_$$", 3998 ) ) );
    is_deeply [ $one->refunded_cents($adb), $two->refunded_cents($adb) ], [ 1999, 3999 ], 'a cent short of each';
    is reread($one)->state, 'active', 'still neither ends';
    is reread($two)->state, 'active', 'short of its full amount';

    {
        local $SIG{__WARN__} = sub { };    # a deliberate over-refund, logged; its line is the next subtest's
        deliver( refund_event( 'refund.created', $ACCOUNT_A, refund( "re_cart3_$$", "pi_cart_$$", 5000 ) ) );
    }
    is_deeply [ $one->refunded_cents($adb), $two->refunded_cents($adb) ], [ 2000, 4000 ],
        'the rest of the payment reaches each full amount, and no more';
    is reread($one)->state, 'refunded', 'ending the first';
    is reread($two)->state, 'refunded', 'and the second';
};

subtest 'ending frees only own units' => sub {
    my $occurrence = occurrence();
    my ($ended) = booking( payment( 2000, "pi_own1_$$" ), 2000, 2, $occurrence );
    my ($kept)  = booking( payment( 1000, "pi_own2_$$" ), 1000, 1, $occurrence );
    my $kept_units = $kept->units( $adb, $occurrence->id );

    deliver( refund_event( 'refund.created', $ACCOUNT_A, refund( "re_own_$$", "pi_own1_$$", 2000 ) ) );
    is reread($ended)->state, 'refunded', 'the refunded entitlement ends';
    is reread($kept)->state, 'active', 'the other on the occurrence does not';
    is_deeply $occurrence->held_units($adb), $kept_units, 'which still holds its own seat, and only it is held';
    is $occurrence->free_units($adb), 3, 'so the two refunded seats are free';
};

subtest 'partial apply failure rolls back' => sub {
    my $paid = payment( 2000, "pi_fail_$$" );
    my ( $e, $occurrence ) = booking( $paid, 2000, 1 );
    # A failure between recording the refund and ending the entitlement.
    $adb->query(q{CREATE FUNCTION srm_fail() RETURNS trigger LANGUAGE plpgsql
                  AS $$ BEGIN RAISE EXCEPTION 'injected failure'; END $$});
    $adb->query('CREATE TRIGGER srm_fail BEFORE UPDATE ON entitlements FOR EACH ROW EXECUTE FUNCTION srm_fail()');
    my $runs = count('workflow_runs');

    my $event = refund_event( 'refund.created', $ACCOUNT_A, refund( "re_fail_$$", "pi_fail_$$", 2000 ) );
    $event->{id} = "evt_fail_$$";
    deliver($event);
    $adb->query('DROP TRIGGER srm_fail ON entitlements');
    $adb->query('DROP FUNCTION srm_fail()');

    is reread($e)->state, 'active', 'the entitlement is not ended';
    is $occurrence->free_units($adb), 3, 'its seat is still taken';
    is_deeply records($e), [], 'the refund record rolled back with it';
    ok !processed_at("evt_fail_$$"), 'and the event is left unapplied';
    my ($run) = Registry::DAO::WorkflowRun->find( $adb, { id => $adb->query(
        'SELECT id FROM workflow_runs ORDER BY created_at DESC LIMIT 1')->array->[0] } );
    is count('workflow_runs'), $runs + 1, 'one run was started';
    like $run->data->{__driver}{error}, qr/injected failure/, 'which records the failure for its retry';

    is drive($run)->{state}, 'finished', 'once the fault is gone, the retry applies it';
    is reread($e)->state, 'refunded', 'ending the entitlement';
    is $occurrence->free_units($adb), 4, 'and freeing its seat';
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
        forget_inherited_handles();
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
    reap($pid);
    return ( $blocked, Mojo::JSON::from_json( do { local $/; readline $parent_reads } ) );
}

subtest 'concurrent duplicate event applied once' => sub {
    my $paid = payment( 3000, "pi_race_$$" );
    my ($e) = booking( $paid, 3000 );
    my $event = refund_event( 'refund.created', $ACCOUNT_A, refund( "re_race_$$", "pi_race_$$", 1000 ) );
    $event->{id} = "evt_race_$$";
    Test::Registry::StripeWebhook::post_connect( $t, {%$event} )->status_is(200);

    my @runs = map { move_run("evt_race_$$") } 1 .. 2;
    my sub apply ( $run, $h ) {
        my $r = Registry::DAO::WorkflowRun->find( $h, { id => $run->id } );
        return $r->process( $h, $r->next_step($h), {} );
    }
    my ( $blocked, $second ) = race( sub ($h) { apply( $runs[0], $h ) }, sub ($h) { apply( $runs[1], $h ) } );
    ok $blocked, 'the second application waited for the first';
    ok !$second->{died}, 'and then finished without error' or diag $second->{died};
    is_deeply records($e), [1000], 'the refund is recorded once';
    is reread($e)->state, 'active', 'and the entitlement stays in effect';
    ok processed_at("evt_race_$$"), 'the event is applied';
    $minion->perform_jobs;
    is_deeply records($e), [1000], 'and the queued run for it adds nothing';
};

subtest 'a refund Registry made that settles from pending ends the entitlement' => sub {
    my $paid = payment( 2000, "pi_held_$$" );
    my ( $e, $occurrence ) = booking( $paid, 2000 );
    # Registry's own refund call, answered pending by Stripe: held on the payment.
    my $pending = refund( "re_held_$$", "pi_held_$$", 2000, 'pending' );
    $paid->_apply_refund_result( $adb, $pending, 2000, 'requested_by_customer', 0, "refund:direct:$$" );
    deliver( refund_event( 'refund.created', $ACCOUNT_A, $pending ) );
    is reread($e)->state, 'active', 'held while Stripe says pending';
    my $runs = count('workflow_runs');

    my $done = refund_event( 'refund.updated', $ACCOUNT_A, refund( "re_held_$$", "pi_held_$$", 2000 ) );
    $done->{id} = "evt_held_done_$$";
    deliver($done);
    is $adb->query( 'SELECT refunded_cents FROM payments WHERE id = ?', $paid->id )->array->[0], 2000,
        "the payment's held refund is settled";
    is reread($e)->state,        'refunded',   'and the entitlement ends';
    is reread($e)->ended_reason, "re_held_$$", 'naming the refund';
    is $occurrence->free_units($adb), 4, 'with its seat freed';
    ok processed_at("evt_held_done_$$"), 'the event is applied';
    is count('workflow_runs'), $runs + 1, 'by one run';

    Test::Registry::StripeWebhook::post_connect( $t, {%$done} )->status_is(200)->content_is('OK (duplicate)');
    $minion->perform_jobs;
    is count('workflow_runs'), $runs + 1, 'a redelivery starts no second run';
    is $e->refunded_cents($adb), 2000, 'and records nothing more';
};

subtest 'charge refunded without a refunds list applies nothing' => sub {
    my $paid = payment( 2000, "pi_nolist_$$" );
    my ($e) = booking( $paid, 2000 );
    my $runs  = count('workflow_runs');
    my $event = charge_refunded( $ACCOUNT_A, "pi_nolist_$$" );
    delete $event->{data}{object}{refunds};
    $event->{data}{object}{amount_refunded} = 2000;
    deliver($event);
    is count('workflow_runs'), $runs, 'it starts no run';
    is reread($e)->state, 'active', 'and leaves the entitlement in effect';
    is_deeply records($e), [], 'with nothing recorded';
};

subtest 'an over-refund is capped and logged' => sub {
    my $paid = payment( 2000, "pi_over_$$" );
    my ($e) = booking( $paid, 2000 );
    my $event = refund_event( 'refund.created', $ACCOUNT_A, refund( "re_over_$$", "pi_over_$$", 2500 ) );
    $event->{id} = "evt_over_$$";
    Test::Registry::StripeWebhook::post_connect( $t, {%$event} )->status_is(200);

    my @warned;
    local $SIG{__WARN__} = sub { push @warned, @_ };
    my $run = move_run("evt_over_$$");
    $run->process( $adb, $run->next_step($adb), {} );
    is $e->refunded_cents($adb), 2000, 'no more than its share is recorded';
    is reread($e)->state, 'refunded', 'and it ends';
    is scalar @warned, 1, 'one line is logged';
    like $warned[0], qr/re_over_$$.*2500.*2000/, 'naming the refund, what Stripe reported and what was applied';
    $minion->perform_jobs;    # the endpoint's own run finds it applied
};

done_testing;
