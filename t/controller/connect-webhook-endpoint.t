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
    my $event = { id => "evt_conn_known_$$", type => 'customer.created', account => $account,
                  data => { object => { id => 'cus_conn' } } };

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

done_testing;
