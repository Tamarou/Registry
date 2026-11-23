#!/usr/bin/env perl
# ABOUTME: Refund, dispute and customer events from the Connect endpoint are stored for replay, not applied.
# ABOUTME: Each is kept once with its account, resolved tenant and payload; no payment row changes.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Payment;
use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::StripeWebhook;

local $ENV{STRIPE_SECRET_KEY}             = 'sk_test_connect_moves';
local $ENV{STRIPE_WEBHOOK_SECRET}         = 'whsec_local_platform_moves';
local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_local_connect_moves';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $slug    = 'conn_moves_' . $$;
my $account = 'acct_conn_moves_' . $$;

my $admin = Registry::DAO::User->create($db, {
    username  => "conn_moves_admin_$$",
    email     => "conn_moves_admin_$$\@test.example",
    name      => 'Connect Moves Admin',
    user_type => 'admin',
});
my $tenant = Registry::DAO::Tenant->provision($db, {
    name  => "Connect Moves Tenant $$",
    slug  => $slug,
    users => [ $admin ],
    stripe_connect_account_id => $account,
});

my $tdb = Registry::DAO->new(url => $ENV{DB_URL}, schema => $slug)->db;
my $parent = Registry::DAO::User->create($tdb, {
    username  => "conn_moves_parent_$$",
    email     => "conn_moves_parent_$$\@test.example",
    name      => 'Connect Moves Parent',
    user_type => 'parent',
});
my $payment = Registry::DAO::Payment->create($tdb, {
    user_id                  => $parent->id,
    amount_cents             => 15000,
    status                   => 'completed',
    stripe_payment_intent_id => "pi_conn_moves_$$",
    metadata                 => { tenant_slug => $slug },
});

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });
$t->app->log->unsubscribe('message');

sub stored ($event_id) {
    return $db->query(
        q{SELECT account, tenant_id, payload, processed_at
            FROM registry.webhook_events WHERE stripe_event_id = ?}, $event_id
    )->expand->hashes;
}

sub payment_row () {
    return $tdb->query(q{SELECT * FROM payments WHERE id = ?}, $payment->id)->hash;
}

sub refund_event (%over) {
    return {
        id      => "evt_moves_refund_$$",
        type    => 'charge.refunded',
        account => $account,
        data    => { object => {
            id              => "ch_conn_moves_$$",
            object          => 'charge',
            amount          => 15000,
            amount_refunded => 15000,
            refunded        => Mojo::JSON::true,
            payment_intent  => "pi_conn_moves_$$",
            metadata        => { payment_id => $payment->id, tenant_slug => $slug },
        } },
        %over,
    };
}

subtest 'refund event is stored with account tenant and payload unapplied' => sub {
    my $before = payment_row();
    my $event  = refund_event();

    Test::Registry::StripeWebhook::post_connect($t, {%$event})
        ->status_is(200)->content_is('OK');

    my $rows = stored($event->{id});
    is scalar @$rows, 1, 'stored once';
    is $rows->[0]{account},   $account,     'with the connected account';
    is $rows->[0]{tenant_id}, $tenant->id,  'with the tenant the account names';
    is_deeply $rows->[0]{payload}, Mojo::JSON::decode_json(Mojo::JSON::encode_json($event)),
        'with the full payload';
    is $rows->[0]{processed_at}, undef, 'and left unapplied';
    is_deeply payment_row(), $before, 'the payment row is unchanged';
};

done_testing;
