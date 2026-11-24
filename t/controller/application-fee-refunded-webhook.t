#!/usr/bin/env perl
# ABOUTME: application_fee.refunded at the platform endpoint records how much of the fee went back, on the tenant's payment.
# ABOUTME: Stripe reports it; Registry keeps the highest amount reported, so a redelivery or a late older event changes nothing.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use experimental qw(defer signatures);
use Test::More import => [qw( done_testing is ok subtest )];
defer { done_testing };

use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::StripeWebhook;
use Registry::DAO::Tenant;
use Registry::Service::Stripe;
use Mojo::Promise;

local $ENV{STRIPE_WEBHOOK_SECRET}         = 'whsec_local_platform_fee_refunded';
local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_local_connect_fee_refunded';

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
$ENV{DB_URL} = $t_db->uri;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $dao } );

my @logs;
$t->app->log->unsubscribe('message');
$t->app->log->level('info');
$t->app->log->on( message => sub ( $log, $level, @lines ) { push @logs, [ $level, "@lines" ] } );

sub tenant ( $name ) {
    my $slug  = "feeref_${name}_$$";
    my $admin = $dao->create( User => { username => "feeref_${name}_admin_$$", user_type => 'admin' } );
    Registry::DAO::Tenant->provision( $dao->db, {
        name  => "Fee refund $name $$",
        slug  => $slug,
        users => [$admin],
        stripe_connect_account_id => "acct_feeref_${name}_$$",
    } );
    my $tdao = $dao->connect_schema($slug);
    my $user = $tdao->create( User => { username => "feeref_${name}_parent_$$", user_type => 'parent' } );
    return { slug => $slug, account => "acct_feeref_${name}_$$", db => $tdao->db, user => $user };
}

my $A = tenant('a');

# A completed direct charge on the seller's account, its fee recorded.
sub completed_payment ( $tenant, $intent ) {
    return $tenant->{db}->insert( 'payments', {
        user_id                  => $tenant->{user}->id,
        amount_cents             => 10000,
        currency                 => 'USD',
        status                   => 'completed',
        stripe_payment_intent_id => $intent,
        platform_fee_cents       => 250,
        metadata                 => { -json => { stripe_account_id => $tenant->{account} } },
    }, { returning => 'id' } )->hash->{id};
}

sub refunded_cents ( $tenant, $id ) {
    return $tenant->{db}->select( 'payments', ['platform_fee_refunded_cents'], { id => $id } )
        ->hash->{platform_fee_refunded_cents};
}

# The charge lookup, answered here on the account it was asked on and never
# sent to Stripe. A charge not listed is one Stripe could not return.
my %CHARGES;
my @lookups;
no warnings 'redefine';
local *Registry::Service::Stripe::retrieve_charge_async = sub ( $s, $id ) {
    push @lookups, [ $s->stripe_account, $id ];
    my $charge = $CHARGES{$id}
        or return Mojo::Promise->reject("Stripe invalid_request_error: No such charge: '$id'");
    return Mojo::Promise->resolve($charge);
};
use warnings 'redefine';

# Signed with the platform secret and posted to the platform endpoint, as
# Stripe sends an event on the platform's own account.
sub fee_refunded ( %fee ) {
    my %opts = map { $_ => delete $fee{$_} } grep { exists $fee{$_} } qw( id secret );
    return Test::Registry::StripeWebhook::post_connect( $t, {
        ( $opts{id} ? ( id => $opts{id} ) : () ),
        type => 'application_fee.refunded',
        data => { object => { object => 'application_fee', amount => 250, %fee } },
    }, path => '/webhooks/stripe', secret => $opts{secret} // $ENV{STRIPE_WEBHOOK_SECRET} );
}

subtest 'the refunded fee is recorded on the tenant payment, idempotently' => sub {
    my $id = completed_payment( $A, 'pi_feeref_one' );
    $CHARGES{ch_feeref_one} = { id => 'ch_feeref_one', payment_intent => 'pi_feeref_one' };

    fee_refunded( id => 'evt_feeref_one', account => $A->{account},
        charge => 'ch_feeref_one', amount_refunded => 100 )->status_is(200);
    is refunded_cents( $A, $id ), 100, 'what Stripe reports as refunded is recorded';
    is_deeply_lookup( $A->{account}, 'ch_feeref_one' );

    fee_refunded( id => 'evt_feeref_one', account => $A->{account},
        charge => 'ch_feeref_one', amount_refunded => 100 )->status_is(200);
    is refunded_cents( $A, $id ), 100, 'a redelivery leaves it unchanged';
};

sub is_deeply_lookup ( $account, $charge ) {
    my $last = $lookups[-1] // [];
    is "@$last", "$account $charge", 'the charge is read on the seller account the fee names';
}

my $B = tenant('b');

sub claimed ( $event_id ) {
    return $dao->db->select( 'registry.webhook_events', ['id'], { stripe_event_id => $event_id } )->rows;
}

subtest 'unknown account changes no payment' => sub {
    my $in_a        = completed_payment( $A, 'pi_feeref_unknown' );
    my $platform_parent = $dao->create( User => { username => "feeref_platform_parent_$$", user_type => 'parent' } );
    my $in_registry = $dao->db->insert( 'registry.payments', {
        user_id => $platform_parent->id, amount_cents => 10000, status => 'completed',
        stripe_payment_intent_id => 'pi_feeref_unknown', platform_fee_cents => 250,
    }, { returning => 'id' } )->hash->{id};
    $CHARGES{ch_feeref_unknown} = { id => 'ch_feeref_unknown', payment_intent => 'pi_feeref_unknown' };
    @logs = ();

    fee_refunded( account => "acct_nobody\n_$$", charge => 'ch_feeref_unknown',
        amount_refunded => 250 )->status_is(200);
    is refunded_cents( $A, $in_a ), undef, 'no tenant payment changes';
    is $dao->db->select( 'registry.payments', ['platform_fee_refunded_cents'],
        { id => $in_registry } )->hash->{platform_fee_refunded_cents}, undef,
        'nor the platform schema payment';
    ok( ( grep { $_->[0] eq 'warn' && $_->[1] =~ /acct_nobody\\x\{a\}_/ } @logs ),
        'the unknown account is logged, escaped' );
};

subtest 'charge matching no payment in tenant changes nothing' => sub {
    my $in_b = completed_payment( $B, 'pi_feeref_b_only' );
    $CHARGES{ch_feeref_b_only} = { id => 'ch_feeref_b_only', payment_intent => 'pi_feeref_b_only' };
    @logs = ();

    fee_refunded( account => $A->{account}, charge => 'ch_feeref_b_only',
        amount_refunded => 250 )->status_is(200);
    is refunded_cents( $B, $in_b ), undef, "tenant B's payment with the same ids is untouched";
    ok( ( grep { $_->[1] =~ /matched no payment/ } @logs ), 'the miss is logged' );
};

subtest 'older lower amount refunded never lowers the record' => sub {
    my $id = completed_payment( $A, 'pi_feeref_order' );
    $CHARGES{ch_feeref_order} = { id => 'ch_feeref_order', payment_intent => 'pi_feeref_order' };

    fee_refunded( account => $A->{account}, charge => 'ch_feeref_order',
        amount_refunded => 200 )->status_is(200);
    fee_refunded( account => $A->{account}, charge => 'ch_feeref_order',
        amount_refunded => 100 )->status_is(200);
    is refunded_cents( $A, $id ), 200, 'the newer, higher amount stands';
};

subtest 'wrong secret or bad signature is refused' => sub {
    my $id = completed_payment( $A, 'pi_feeref_sig' );
    $CHARGES{ch_feeref_sig} = { id => 'ch_feeref_sig', payment_intent => 'pi_feeref_sig' };

    fee_refunded( id => 'evt_feeref_connect_secret', secret => $ENV{STRIPE_CONNECT_WEBHOOK_SECRET},
        account => $A->{account}, charge => 'ch_feeref_sig', amount_refunded => 250 )
        ->status_is(400);
    fee_refunded( id => 'evt_feeref_bad_sig', secret => 'whsec_forged',
        account => $A->{account}, charge => 'ch_feeref_sig', amount_refunded => 250 )
        ->status_is(400);
    is refunded_cents( $A, $id ), undef, 'nothing is recorded';
    ok !claimed('evt_feeref_connect_secret') && !claimed('evt_feeref_bad_sig'), 'nor claimed';
};

subtest 'charge lookup failure leaves event unclaimed' => sub {
    my $id = completed_payment( $A, 'pi_feeref_retry' );

    fee_refunded( id => 'evt_feeref_retry', account => $A->{account},
        charge => 'ch_feeref_retry', amount_refunded => 250 )->status_is(500);
    ok !claimed('evt_feeref_retry'), 'the event is not claimed';
    is refunded_cents( $A, $id ), undef, 'nothing is recorded yet';

    $CHARGES{ch_feeref_retry} = { id => 'ch_feeref_retry', payment_intent => 'pi_feeref_retry' };
    fee_refunded( id => 'evt_feeref_retry', account => $A->{account},
        charge => 'ch_feeref_retry', amount_refunded => 250 )->status_is(200);
    is refunded_cents( $A, $id ), 250, "Stripe's redelivery is recorded";
};

subtest 'fee refunded event never reaches subscription handler' => sub {
    require Registry::DAO::Subscription;
    my $calls = 0;
    no warnings 'redefine';
    local *Registry::DAO::Subscription::process_webhook_event = sub { $calls++ };
    use warnings 'redefine';

    my $id = completed_payment( $A, 'pi_feeref_sub' );
    $CHARGES{ch_feeref_sub} = { id => 'ch_feeref_sub', payment_intent => 'pi_feeref_sub' };
    fee_refunded( account => $A->{account}, charge => 'ch_feeref_sub',
        amount_refunded => 50 )->status_is(200);
    fee_refunded( account => 'acct_nobody_sub', charge => 'ch_feeref_sub',
        amount_refunded => 50 )->status_is(200);
    is $calls, 0, 'the subscription handler is never called';
    is refunded_cents( $A, $id ), 50, 'the fee refund is recorded instead';
};
