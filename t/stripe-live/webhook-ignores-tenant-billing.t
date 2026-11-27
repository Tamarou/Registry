#!/usr/bin/env perl
# ABOUTME: With tenant billing gone, a failed instalment invoice from a real Stripe schedule still marks its row at the Connect endpoint.
# ABOUTME: Requires STRIPE_SECRET_KEY (sk_test_); skips entirely without one.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use experimental qw(signatures);
use Test::More;
use Test::Registry::StripeConnect;

plan skip_all => 'STRIPE_SECRET_KEY (sk_test_) not set'
    unless Test::Registry::StripeConnect::available();

require Test::Registry::DB;
require Test::Registry::Mojo;
require Test::Registry::StripeWebhook;
require Registry::Service::Stripe;
require Registry::DAO::Payment;
require Registry::DAO::Tenant;

local $ENV{STRIPE_WEBHOOK_SECRET}         = 'whsec_live_platform_tenant_billing';
local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_live_connect_tenant_billing';

# Set once the tenant account exists; cleanup acts on that account.
my $stripe;
my @schedules;
my @customers;
END {
    local $?;
    my $s = $stripe or return;

    # Schedules first: a customer with a live schedule cannot be deleted.
    for my $id (@schedules) {
        eval { $s->cancel_subscription_schedule($id); 1 }
            or warn "# could not cancel $id: $@";
    }
    for my $id (@customers) {
        eval { $s->_await( $s->delete_customer_async($id) ); 1 }
            or warn "# could not delete $id: $@";
    }
}

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $dao } );

# The webhook reads the subscription on event.account, so everything lives on
# a connected account, as production's seller-bound client puts it there.
my $acct = Test::Registry::StripeConnect::ready_account();
like $acct, qr/^acct_/, "a charges_enabled connected account ($acct)";
$stripe = Registry::Service::Stripe->from_env->for_account($acct);

# The tenant that account belongs to, with a parent to own the instalments.
my $slug  = "live_tb_$$";
my $admin = $dao->create( User => { username => "live_tb_admin_$$", user_type => 'admin' } );
Registry::DAO::Tenant->provision( $dao->db, {
    name => "Live Tenant Billing $$", slug => $slug, users => [$admin],
    stripe_connect_account_id => $acct,
} );
my $tdb    = $dao->connect_schema($slug)->db;
my $parent = $dao->connect_schema($slug)
    ->create( User => { username => "live_tb_parent_$$", user_type => 'parent' } );

my $customer = $stripe->create_customer({
    email               => 'instalments@tamarou.com',
    'metadata[purpose]' => 'registry-test-suite',
});
push @customers, $customer->{id};

my $pm = $stripe->_await( $stripe->create_payment_method_async({
    type => 'card', 'card[token]' => 'tok_visa' }) );
$stripe->_await( $stripe->attach_payment_method_async( $pm->{id}, $customer->{id} ) );

my $product = $stripe->_await( $stripe->create_product_async({
    name => 'Summer Camp', 'metadata[purpose]' => 'registry-test-suite' }) );

subtest 'instalment invoice still handled' => sub {
    my $params = Registry::DAO::Payment::instalment_schedule_params({
        product           => $product->{id},
        customer          => $customer->{id},
        payment_method    => $pm->{id},
        revenue_share_pct => 2.5,
        currency          => 'usd',
        description       => 'Summer Camp',
        cadence           => 'monthly',
        entitlement_id    => '00000000-0000-4000-8000-0000000000f2',
        instalments       => [
            { amount_cents => 3333, due_date => '2027-07-01' },
            { amount_cents => 3334, due_date => '2027-08-01' },
        ],
    });
    # Starting now, so Stripe makes the subscription and its first invoice at once.
    $params->{start_date} = 'now';

    my $schedule = eval { $stripe->create_subscription_schedule($params) };
    ok $schedule, 'the schedule was created' or do { diag $@; return };
    push @schedules, $schedule->{id};

    # The set as schedule_remaining_instalments leaves it: instalment one paid,
    # the rest owed against the schedule Stripe just made.
    my @ids;
    for my $i ( 1 .. 3 ) {
        push @ids, $tdb->insert( 'payments', {
            user_id            => $parent->id,
            amount_cents       => $i == 3 ? 3334 : 3333,
            currency           => 'USD',
            status             => $i == 1 ? 'completed' : 'pending',
            instalment_seq     => $i,
            instalment_count   => 3,
            due_date           => sprintf( '2027-%02d-01', 5 + $i ),
            stripe_schedule_id => $schedule->{id},
            metadata           => { -json => { stripe_account_id => $acct } },
        }, { returning => 'id' } )->hash->{id};
    }

    my $subscription = $stripe->_await(
        $stripe->retrieve_subscription_async( $schedule->{subscription} ) );
    my $invoice = $stripe->_await(
        $stripe->retrieve_invoice_async( $subscription->{latest_invoice} ) );

    # Stripe's own invoice, reported failed as Stripe would report a decline.
    Test::Registry::StripeWebhook::post_connect( $t, {
        type    => 'invoice.payment_failed',
        account => $acct,
        created => time,
        data    => { object => { %$invoice, payment_intent => $invoice->{payment_intent} // "pi_live_tb_$$" } },
    } )->status_is(200)->content_is('OK');

    my $rows = $tdb->query( 'SELECT status, metadata FROM payments WHERE id = ANY(?) ORDER BY instalment_seq',
        \@ids )->expand->hashes;
    is_deeply [ map { $_->{status} } @$rows ], [qw( completed failed pending )],
        'the first owed instalment is marked failed, not swallowed as tenant billing';
    is $rows->[1]{metadata}{stripe_invoice_id}, $invoice->{id}, 'and bound to that invoice';
};

done_testing;
