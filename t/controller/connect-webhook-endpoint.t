#!/usr/bin/env perl
# ABOUTME: The Connect webhook endpoint verifies with its own secret and finds the tenant from event.account.
# ABOUTME: Covers the claim, dedup, refused signatures, and events no tenant can settle.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::StripeWebhook;
use Mojo::JSON;

local $ENV{STRIPE_SECRET_KEY}             = 'sk_test_connect_endpoint';
local $ENV{STRIPE_WEBHOOK_SECRET}         = 'whsec_local_platform_endpoint';
local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_local_connect_endpoint';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $slug    = 'conn_wh_' . $$;
my $account = 'acct_conn_wh_' . $$;

my $admin = Registry::DAO::User->create($db, {
    username  => "conn_wh_admin_$$",
    email     => "conn_wh_admin_$$\@test.example",
    name      => 'Connect WH Admin',
    user_type => 'admin',
});
Registry::DAO::Tenant->provision($db, {
    name  => "Connect WH Tenant $$",
    slug  => $slug,
    users => [ $admin ],
    stripe_connect_account_id => $account,
});

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

# Every log line the app writes, kept here instead of on stderr.
my @logs;
$t->app->log->unsubscribe('message');
$t->app->log->level('info');
$t->app->log->on(message => sub ($log, $level, @lines) { push @logs, [ $level, "@lines" ] });

sub claims ($event_id) {
    return $db->select('registry.webhook_events', ['processed_at'],
        { stripe_event_id => $event_id })->hashes;
}

subtest 'a connect event for a known account is claimed once' => sub {
    @logs = ();
    my $event = { id => "evt_conn_known_$$", type => 'product.created', account => $account,
                  data => { object => { id => 'prod_conn' } } };

    Test::Registry::StripeWebhook::post_connect($t, {%$event})
        ->status_is(200)->content_is('OK');

    my $rows = claims($event->{id});
    is scalar @$rows, 1, 'the event is claimed';
    ok $rows->[0]{processed_at}, 'and marked processed';
    ok scalar( grep { $_->[1] =~ /\Q$slug\E/ } @logs ),
        'routed to the tenant event.account names';

    Test::Registry::StripeWebhook::post_connect($t, {%$event})
        ->status_is(200)->content_is('OK (duplicate)');
    is scalar @{ claims($event->{id}) }, 1, 'a redelivery claims nothing more';
};

subtest 'platform signed delivery is refused' => sub {
    my $event = { id => "evt_conn_platform_$$", type => 'customer.created', account => $account };
    Test::Registry::StripeWebhook::post_connect($t, $event,
        secret => $ENV{STRIPE_WEBHOOK_SECRET})->status_is(400);
    is scalar @{ claims($event->{id}) }, 0, 'nothing is claimed';
};

subtest 'missing connect secret answers 500' => sub {
    @logs = ();
    my $event = { id => "evt_conn_nosecret_$$", type => 'customer.created', account => $account };
    {
        my $signed_with = $ENV{STRIPE_CONNECT_WEBHOOK_SECRET};
        delete local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET};
        Test::Registry::StripeWebhook::post_connect($t, $event, secret => $signed_with)
            ->status_is(500);
    }
    ok scalar( grep { $_->[0] eq 'error' && $_->[1] =~ /STRIPE_CONNECT_WEBHOOK_SECRET/ } @logs ),
        'the missing secret is logged as an error';
    is scalar @{ claims($event->{id}) }, 0, 'nothing is claimed';
};

subtest 'unknown account settles into no schema' => sub {
    @logs = ();
    my $event = { id => "evt_conn_unknown_$$", type => 'customer.created',
                  account => 'acct_nobody_' . $$ };
    Test::Registry::StripeWebhook::post_connect($t, $event)->status_is(200);
    ok scalar( grep { $_->[1] =~ /acct_nobody_$$/ } @logs ), 'the unknown account is logged';
    is scalar @{ claims($event->{id}) }, 0, 'nothing is claimed or settled';
};

subtest 'connect signed delivery to platform endpoint is refused' => sub {
    my $event = { id => "evt_conn_to_platform_$$", type => 'payment_intent.succeeded',
                  account => $account, data => { object => { id => 'pi_conn', metadata => {} } } };
    Test::Registry::StripeWebhook::post_connect($t, $event, path => '/webhooks/stripe')
        ->status_is(400);
    is scalar @{ claims($event->{id}) }, 0, 'nothing is claimed';
};

subtest 'altered body missing or stale signature is refused' => sub {
    my $event = { id => "evt_conn_tamper_$$", type => 'customer.created', account => $account };

    my $altered = Mojo::JSON::encode_json({ %$event, account => 'acct_attacker' });
    Test::Registry::StripeWebhook::post_connect($t, {%$event}, body => $altered)
        ->status_is(400, 'a body altered after signing');

    $t->tx( $t->ua->post('/webhooks/stripe/connect' => { 'Content-Type' => 'application/json' }
        => Mojo::JSON::encode_json($event)) )->status_is(400, 'no signature header');

    Test::Registry::StripeWebhook::post_connect($t, {%$event}, timestamp => time() - 600)
        ->status_is(400, 'a timestamp outside the tolerance');

    is scalar @{ claims($event->{id}) }, 0, 'nothing is claimed';
};

subtest 'event without account never defaults to registry' => sub {
    @logs = ();
    my $event = { id => "evt_conn_noacct_$$", type => 'customer.created' };
    Test::Registry::StripeWebhook::post_connect($t, $event)
        ->status_is(200)->content_is('OK (no tenant)');
    ok scalar( grep { $_->[1] =~ /\Q$event->{id}\E/ } @logs ), 'the event is logged';
    ok !scalar( grep { $_->[1] =~ /for tenant/ } @logs ), 'and routed to no tenant, registry included';
    is scalar @{ claims($event->{id}) }, 0, 'nothing is claimed or settled';
};

subtest 'case prefix or injected account resolves no tenant' => sub {
    my $prefix = substr $account, 0, -1;
    for my $impostor ( uc($account), $prefix, "$prefix%", "acct_x' OR '1'='1", "$account' --" ) {
        my $event = { type => 'customer.created', account => $impostor };
        Test::Registry::StripeWebhook::post_connect($t, $event)
            ->status_is(200)->content_is('OK (no tenant)', "'$impostor' names no tenant");
        is scalar @{ claims($event->{id}) }, 0, 'and claims nothing';
    }
};

subtest 'already claimed event id is a duplicate' => sub {
    @logs = ();
    my $event_id = "evt_conn_claimed_$$";

    # A different backend from the app's: the claim it sees is a committed one.
    my $other = Registry::DAO->new( url => $test_db->uri )->db;
    $other->query(
        q{INSERT INTO registry.webhook_events (stripe_event_id, event_type) VALUES (?, ?)},
        $event_id, 'customer.created' );

    Test::Registry::StripeWebhook::post_connect($t,
        { id => $event_id, type => 'customer.created', account => $account })
        ->status_is(200)->content_is('OK (duplicate)');

    my $rows = claims($event_id);
    is scalar @$rows, 1, 'still one claim';
    ok !$rows->[0]{processed_at}, 'and nothing processed it';
    ok !scalar( grep { $_->[1] =~ /for tenant/ } @logs ), 'no handling was attempted';
};

done_testing;
