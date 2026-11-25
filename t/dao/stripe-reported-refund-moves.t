#!/usr/bin/env perl
# ABOUTME: Refunds Stripe reports on a tenant's account are applied to the entitlements their payment bought.
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
use Test::Registry::Helpers qw( authenticate_as import_all_workflows join_tenant );
use Test::Registry::Fixtures;
use Registry::DAO;
use Registry::DAO::Entitlement;
use Registry::DAO::Offer;
use Registry::DAO::Payment;
use Registry::DAO::Resource;
use Registry::DAO::Tenant;
use Registry::DAO::User;

local $ENV{STRIPE_WEBHOOK_SECRET}         = 'whsec_local_platform_refund_moves';
local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_local_connect_refund_moves';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;
import_all_workflows($dao);

my $admin = Registry::DAO::User->create( $db, {
    username => "srm_admin_$$", email => "srm_admin_$$\@test.example", name => 'SRM Admin', user_type => 'admin' } );

# A tenant on its own connected account, provisioned with every workflow.
sub tenant ($name) {
    my $slug = "srm_${name}_$$";
    Registry::DAO::Tenant->provision( $db, {
        name => "SRM $name $$", slug => $slug, users => [$admin], stripe_connect_account_id => "acct_$slug" } );
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
    my $room = $tdb->insert( 'locations', { name => 'Room ' . ++$made, slug => "srm-room-$made" },
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

done_testing;
