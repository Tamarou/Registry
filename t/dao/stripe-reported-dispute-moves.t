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

done_testing;
