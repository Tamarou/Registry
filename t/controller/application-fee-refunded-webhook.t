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
