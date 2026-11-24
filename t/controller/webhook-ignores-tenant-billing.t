#!/usr/bin/env perl
# ABOUTME: The platform webhook endpoint answers tenant-billing and unknown events 200, logs them and acts on nothing.
# ABOUTME: Under revenue share there is no tenant subscription billing; instalments settle at the Connect endpoint.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use experimental qw(defer signatures);
use Test::More import => [qw( done_testing is ok is_deeply subtest )];
defer { done_testing };

use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::StripeWebhook;

local $ENV{STRIPE_WEBHOOK_SECRET}         = 'whsec_local_platform_tenant_billing';
local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_local_connect_tenant_billing';

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
my $db   = $dao->db;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $dao } );

my @logs;
$t->app->log->unsubscribe('message');
$t->app->log->level('info');
$t->app->log->on( message => sub ( $log, $level, @lines ) { push @logs, [ $level, "@lines" ] } );

# A tenant as the old subscription billing would have known it.
my $tenant_id = $db->query(
    q{INSERT INTO registry.tenants (name, slug, stripe_customer_id, stripe_subscription_id, billing_status)
      VALUES (?, ?, ?, ?, 'active') RETURNING id},
    "Billing Probe $$", "billing_probe_$$", "cus_probe_$$", "sub_probe_$$" )->hash->{id};

sub tenants () { $db->query('SELECT * FROM registry.tenants ORDER BY id')->hashes->to_array }

# Signed with the platform secret and posted to the platform endpoint.
sub post_platform ( $event, %opts ) {
    Test::Registry::StripeWebhook::post_connect( $t, $event,
        path => '/webhooks/stripe', secret => $ENV{STRIPE_WEBHOOK_SECRET}, %opts );
}

sub subscription_events ($id) {
    $db->query( 'SELECT 1 FROM registry.subscription_events WHERE stripe_event_id = ?', $id )->rows;
}

sub logged ($id) { scalar grep { $_->[1] =~ /\Q$id\E.*not handled/ } @logs }

subtest 'subscription events answered 200 and ignored' => sub {
    my $before = tenants();
    for my $event (
        { id => "evt_sub_updated_$$", type => 'customer.subscription.updated',
          data => { object => { id => "sub_probe_$$", status => 'past_due',
              metadata => { tenant_id => $tenant_id } } } },
        { id => "evt_inv_failed_$$", type => 'invoice.payment_failed',
          data => { object => { id => "in_probe_$$", subscription => "sub_probe_$$",
              billing_reason => 'subscription_cycle' } } },
    ) {
        post_platform($event)->status_is(200);
        ok logged( $event->{id} ), "$event->{type} logged";
        ok !subscription_events( $event->{id} ), "$event->{type} not routed to tenant billing";
    }
    is_deeply tenants(), $before, 'no tenant row changed';
};

subtest 'unsigned tenant billing event refused' => sub {
    my $before = tenants();
    my $event  = { id => "evt_unsigned_$$", type => 'customer.subscription.deleted',
        data => { object => { id => "sub_probe_$$", metadata => { tenant_id => $tenant_id } } } };

    post_platform( $event, secret => 'whsec_not_ours' )->status_is(400);
    is $t->ua->post( '/webhooks/stripe' => { 'Content-Type' => 'application/json' }
        => Mojo::JSON::encode_json($event) )->res->code, 400, 'missing signature refused';

    ok !$db->query( 'SELECT 1 FROM registry.webhook_events WHERE stripe_event_id = ?', $event->{id} )->rows,
        'not claimed';
    ok !subscription_events( $event->{id} ), 'not routed to tenant billing';
    is_deeply tenants(), $before, 'no tenant row changed';
};

subtest 'unknown event type logged and ignored' => sub {
    my $before = tenants();
    my $event  = { id => "evt_unknown_$$", type => 'radar.early_fraud_warning.created',
        data => { object => { id => "issfr_probe_$$" } } };

    post_platform($event)->status_is(200);
    ok logged( $event->{id} ), 'logged';
    ok !subscription_events( $event->{id} ), 'not routed to tenant billing';
    is_deeply tenants(), $before, 'no tenant row changed';
};
