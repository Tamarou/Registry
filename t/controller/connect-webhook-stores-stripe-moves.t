#!/usr/bin/env perl
# ABOUTME: Refund, dispute and customer events from the Connect endpoint are stored for replay, not applied.
# ABOUTME: Each is kept once with its account, resolved tenant and payload; no payment row changes.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use utf8;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Payment;
use Test::Registry::DB;
use Test::Registry::PricingProbe qw( give_tenant_terms state_platform_terms );
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
state_platform_terms( $db, $slug, { rate => 0 } );
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

subtest 'dispute and customer events are stored unapplied once' => sub {
    my $before = payment_row();
    my $users_before = $tdb->query(q{SELECT * FROM users ORDER BY id})->hashes;

    my @events = (
        { id => "evt_moves_dispute_$$", type => 'charge.dispute.closed', account => $account,
          data => { object => { id => "dp_conn_moves_$$", object => 'dispute', status => 'lost',
                                amount => 15000, charge => "ch_conn_moves_$$",
                                payment_intent => "pi_conn_moves_$$" } } },
        { id => "evt_moves_customer_$$", type => 'customer.updated', account => $account,
          data => { object => { id => "cus_conn_moves_$$", object => 'customer',
                                email => "changed_$$\@test.example", name => 'Changed In Stripe' },
                    previous_attributes => { name => 'Connect Moves Parent' } } },
    );

    for my $event (@events) {
        Test::Registry::StripeWebhook::post_connect($t, {%$event})
            ->status_is(200)->content_is('OK', "$event->{type} is answered");
        Test::Registry::StripeWebhook::post_connect($t, {%$event})
            ->status_is(200)->content_is('OK (duplicate)', "its redelivery is a duplicate");

        my $rows = stored($event->{id});
        is scalar @$rows, 1, "$event->{type} is stored once";
        is $rows->[0]{account},   $account,    'with the connected account';
        is $rows->[0]{tenant_id}, $tenant->id, 'with the tenant';
        is_deeply $rows->[0]{payload}, $event, 'with the payload';
        is $rows->[0]{processed_at}, undef, 'and left unapplied';
    }

    is_deeply payment_row(), $before, 'the payment row is unchanged';
    is_deeply $tdb->query(q{SELECT * FROM users ORDER BY id})->hashes, $users_before,
        'no customer row is added or changed';
};

subtest 'bad signature stores nothing' => sub {
    my $event = refund_event( id => "evt_moves_badsig_$$" );
    Test::Registry::StripeWebhook::post_connect($t, $event, secret => 'whsec_not_ours')
        ->status_is(400);
    is scalar @{ stored($event->{id}) }, 0, 'nothing is claimed or stored';
};

subtest 'unlisted event type is claimed but not stored' => sub {
    my $event = { id => "evt_moves_product_$$", type => 'product.created', account => $account,
                  data => { object => { id => "prod_conn_moves_$$" } } };
    Test::Registry::StripeWebhook::post_connect($t, {%$event})->status_is(200);

    my $rows = stored($event->{id});
    is scalar @$rows, 1, 'the event is claimed';
    is $rows->[0]{payload}, undef, 'but its payload is not stored';
    is $rows->[0]{account}, undef, 'nor its account';
    ok $rows->[0]{processed_at}, 'and it is done with, not waiting to be applied';
};

subtest 'stored tenant comes from account not metadata' => sub {
    my $other_slug = 'conn_moves_b_' . $$;
    Registry::DAO::Tenant->provision($db, {
        name  => "Connect Moves Tenant B $$",
        slug  => $other_slug,
        users => [ $admin ],
        stripe_connect_account_id => "acct_conn_moves_b_$$",
    });
    give_tenant_terms( $db, $other_slug, { rate => 0 } );

    my $event = refund_event( id => "evt_moves_metadata_$$" );
    $event->{data}{object}{metadata}{tenant_slug} = $other_slug;
    Test::Registry::StripeWebhook::post_connect($t, {%$event})->status_is(200);

    my $rows = stored($event->{id});
    is scalar @$rows, 1, 'stored once';
    is $rows->[0]{tenant_id}, $tenant->id, "against the account's tenant, not the one metadata names";
};

subtest 'partial and pending refunds are stored unapplied' => sub {
    my $before = payment_row();

    my $partial = refund_event( id => "evt_moves_partial_$$" );
    $partial->{data}{object}{amount_refunded} = 5000;
    $partial->{data}{object}{refunded}        = Mojo::JSON::false;

    my $pending = { id => "evt_moves_pending_$$", type => 'refund.created', account => $account,
                    data => { object => { id => "re_conn_moves_$$", object => 'refund',
                                          amount => 15000, status => 'pending',
                                          charge => "ch_conn_moves_$$",
                                          payment_intent => "pi_conn_moves_$$" } } };

    for my $event ( $partial, $pending ) {
        Test::Registry::StripeWebhook::post_connect($t, {%$event})->status_is(200);
        my $rows = stored($event->{id});
        is scalar @$rows, 1, "$event->{id} is stored";
        is $rows->[0]{processed_at}, undef, 'and left unapplied';
    }

    my $after = payment_row();
    is_deeply $after, $before, 'the payment row is unchanged';
    is $after->{status}, 'completed', 'and the payment is not marked refunded';
    is $after->{refunded_cents}, 0, 'with nothing counted as refunded';
};

subtest 'nested and non ascii payload is stored unchanged' => sub {
    my $event = { id => "evt_moves_unicode_$$", type => 'customer.updated', account => $account,
                  data => { object => {
                      id       => "cus_conn_moves_u_$$",
                      name     => 'Zoë Ñúñez 李小龍',
                      address  => { line1 => 'Straße 5', city => 'Zürich' },
                      metadata => { note => '日本語 — “quoted”' },
                      tax_ids  => [ [ 'eu_vat', [ 'DE123', 'ÄÖÜ' ] ], { codes => [ 1, [ 2, [3] ] ] } ],
                  } } };
    Test::Registry::StripeWebhook::post_connect($t, {%$event})->status_is(200);

    my $rows = stored($event->{id});
    is scalar @$rows, 1, 'stored once';
    is_deeply $rows->[0]{payload}, $event, 'equal to what was sent';
};

subtest 'refund event for unknown account has no tenant' => sub {
    my $event = refund_event( id => "evt_moves_unknown_$$", account => "acct_nobody_moves_$$" );
    Test::Registry::StripeWebhook::post_connect($t, {%$event})->status_is(200);

    my $rows = stored($event->{id});
    is scalar @$rows, 1, 'the event is stored, not lost';
    is $rows->[0]{account}, $event->{account}, 'with the account that sent it';
    ok !defined $rows->[0]{tenant_id}, 'attributed to no tenant';
    ok !defined $rows->[0]{processed_at}, 'and not applied';
};

subtest 'storage failure rolls back claim and answers 500' => sub {
    # Postgres refuses a \u0000 escape in jsonb, so the payload cannot be
    # stored after the claim has been taken.
    my $event = refund_event( id => "evt_moves_nul_$$" );
    $event->{data}{object}{description} = "refund\x{0}";

    Test::Registry::StripeWebhook::post_connect($t, {%$event})->status_is(500);
    is scalar @{ stored($event->{id}) }, 0, 'the claim is rolled back';

    delete $event->{data}{object}{description};
    Test::Registry::StripeWebhook::post_connect($t, {%$event})
        ->status_is(200)->content_is('OK', 'a redelivery is stored, not dropped as a duplicate');
    is scalar @{ stored($event->{id}) }, 1, 'once';
};

done_testing;
