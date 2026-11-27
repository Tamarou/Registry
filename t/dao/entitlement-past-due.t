#!/usr/bin/env perl
# ABOUTME: Past due is a flag on an active entitlement; unpaid and transferred are ended states.
# ABOUTME: Also what an entitlement has paid so far, over its instalment payments and its transfer chain.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Test::Registry::DB;
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO::Resource;
use Registry::DAO::Offer;
use Registry::DAO::Entitlement;
use Registry::DAO::Payment;
use Registry::DAO::Tenant;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

my $tenant = Registry::DAO::Tenant->create( $dao->db, { name => 'Studio past due', slug => 'past_due_studio' } );
$dao->db->query( 'SELECT clone_schema(dest_schema => ?)', 'past_due_studio' );
my $db = $tenant->dao($dao)->db;

my $people = 0;
sub person () {
    return $db->insert( 'users', { username => 'pd' . ++$people }, { returning => 'id' } )->hash->{id};
}

my $resource = Registry::DAO::Resource->create( $db, { name => 'Session seats', kind => 'finite', capacity => 50 } );
my $version  = Registry::DAO::Offer->create( $db, { name => 'Session' } )
    ->draft( $db, offer_terms( $resource->id ) )->publish($db);

# An entitlement holding one seat, with any further columns in %more.
sub seat (%more) {
    return Registry::DAO::Entitlement->grant( $db, {
        holder_user_id   => person(),
        offer_version_id => $version->id,
        payment_plan_id  => 'pay',
        starts_at        => '2020-01-01T00:00:00Z',
        resource_id      => $resource->id,
        units            => 1,
        %more,
    } );
}

sub reread ($e) { scalar Registry::DAO::Entitlement->find( $db, { id => $e->id } ) }

sub payment (%more) {
    return Registry::DAO::Payment->create( $db, {
        user_id => person(), amount_cents => 3000, status => 'completed',
        stripe_payment_intent_id => 'pi_pd_' . ++$people, metadata => {}, %more,
    } );
}

subtest 'past due keeps the entitlement active and the seat held' => sub {
    my $e = seat();
    $e->mark_past_due( $db, 'in_1' );
    $e = reread($e);
    ok $e->is_past_due, 'it is past due';
    is $e->state, 'active', 'and still active';
    my ($unit) = $e->units( $db, $resource->id )->@*;
    ok scalar( grep { $_ == $unit } Registry::DAO::Resource->find( $db, { id => $resource->id } )->held_units($db)->@* ),
        'the resource still holds its seat';
    ok $e->is_in_effect($db), 'and is in effect';
};

subtest 'paying the past due invoice clears it' => sub {
    my $e = seat();
    $e->mark_past_due( $db, 'in_1' );
    $e->clear_past_due( $db, 'in_1' );
    $e = reread($e);
    ok !$e->is_past_due, 'no longer past due';
    ok !defined $e->past_due_since, 'with no past due date';
};

subtest 'an entitlement can end unpaid' => sub {
    my $ended = seat()->end( $db, 'unpaid', 'in_2' );
    is $ended->state,        'unpaid', 'ended unpaid';
    is $ended->ended_reason, 'in_2',   'naming the invoice';
    ok !$ended->is_in_effect($db), 'and is no longer in effect';
};

subtest 'paid cents is the share plus completed instalment rows' => sub {
    my $first = payment();
    my $e2    = seat( payment_id => $first->id, payment_share_cents => 3000 );
    payment( amount_cents => 1500, entitlement_id => $e2->id, instalment_seq => 2, instalment_count => 3 );
    payment( amount_cents => 1500, entitlement_id => $e2->id, instalment_seq => 3, instalment_count => 3,
        status => 'pending', stripe_payment_intent_id => undef );
    is $e2->paid_cents($db), 3000 + 1500, 'share plus completed instalment rows';

    $e2->record_refund( $db, { amount_cents => 500, stripe_refund_id => 're_pd_1' } );
    is $e2->paid_cents($db), 4000, 'less what was refunded';
};

subtest 'chain lists predecessors oldest first' => sub {
    my $first  = payment();
    my $a      = seat( payment_id => $first->id, payment_share_cents => 3000 );
    $a->end( $db, 'transferred', 'moved' );
    my $b = seat( transferred_from_entitlement_id => $a->id );
    $b->end( $db, 'transferred', 'moved again' );
    my $c = seat( transferred_from_entitlement_id => $b->id );
    payment( amount_cents => 700, entitlement_id => $b->id );

    is_deeply [ map { $_->id } $c->chain($db)->@* ], [ $a->id, $b->id, $c->id ], 'oldest first, ending with itself';
    is reread($a)->state, 'transferred', 'a transfer ends the old entitlement transferred';
    is $c->paid_cents($db), 3700, 'paid cents counts the chain';
};

subtest 'another invoice clears nothing' => sub {
    my $e = seat();
    $e->mark_past_due( $db, 'in_1' );
    my $since = reread($e)->past_due_since;
    $e->clear_past_due( $db, 'in_other' );
    $e = reread($e);
    ok $e->is_past_due, 'still past due';
    is $e->past_due_since, $since, 'since the same moment';
};

subtest 'marking past due twice for one invoice changes nothing' => sub {
    my $e = seat();
    $e->mark_past_due( $db, 'in_1' );
    my $since = reread($e)->past_due_since;
    $db->query("SELECT pg_sleep(0.01)");
    $e->mark_past_due( $db, 'in_1' );
    $e = reread($e);
    is $e->past_due_since, $since, 'past due since the first mark';
    $e->clear_past_due( $db, 'in_1' );
    ok !reread($e)->is_past_due, 'one payment of the invoice clears it: it was owed once';
};

subtest 'a second failed invoice keeps it past due until both are paid' => sub {
    my $e = seat();
    $e->mark_past_due( $db, 'in_1' );
    my $first = reread($e)->past_due_since;
    $db->query("SELECT pg_sleep(0.01)");
    $e->mark_past_due( $db, 'in_2' );
    is reread($e)->past_due_since, $first, 'past due since the first failure';

    $e->clear_past_due( $db, 'in_1' );
    $e = reread($e);
    ok $e->is_past_due, 'paying the first leaves it past due';
    ok $e->past_due_since gt $first, 'now since the second failure';

    $e->clear_past_due( $db, 'in_2' );
    $e = reread($e);
    ok !$e->is_past_due, 'paying both clears it';
    ok !defined $e->past_due_since, 'and its date';
};

subtest 'a transfer link cannot be cleared once set' => sub {
    my $from = seat();
    $from->end( $db, 'transferred', 'moved' );
    my $t = seat( transferred_from_entitlement_id => $from->id );
    throws_ok { $db->update( 'entitlements', { transferred_from_entitlement_id => undef }, { id => $t->id } ) }
        qr/keeps/, 'the database refuses';
    is reread($t)->transferred_from_entitlement_id, $from->id, 'and the link stays';
};

subtest 'a partly refunded instalment counts once' => sub {
    my $e = seat( payment_id => payment()->id, payment_share_cents => 3000 );
    payment( amount_cents => 1500, entitlement_id => $e->id, instalment_seq => 2, instalment_count => 3,
        status => 'partially_refunded', refunded_cents => 500 );
    $e->record_refund( $db, { amount_cents => 500, stripe_refund_id => 're_pd_2' } );
    is $e->paid_cents($db), 4000, 'the instalment counts, less its refund once';
};

subtest 'an entitlement cannot be transferred from itself' => sub {
    my $id = $db->query('SELECT gen_random_uuid()')->array->[0];
    throws_ok { seat( id => $id, transferred_from_entitlement_id => $id ) }
        qr/entitlements_transferred_from_check/, 'the database refuses';
};

subtest 'marking an ended entitlement past due marks nothing' => sub {
    my $ended = seat()->end( $db, 'expired', 'occurrence ended' );
    throws_ok { $ended->mark_past_due( $db, 'in_1' ) } qr/not active/, 'it says so';
    ok !reread($ended)->past_due_since, 'and records nothing';
};

subtest 'marking and clearing update the object they are called on' => sub {
    my $e = seat();
    ok $e->mark_past_due( $db, 'in_1' )->is_past_due,   'marked';
    ok !$e->clear_past_due( $db, 'in_1' )->is_past_due, 'cleared';
};

subtest 'an ended entitlement is not past due and keeps its invoices' => sub {
    my $e = seat();
    $e->mark_past_due( $db, 'in_1' );
    my $ended = $e->end( $db, 'unpaid', 'in_1' );
    ok !$ended->is_past_due,         'not past due once ended';
    ok !reread($e)->is_past_due,     'read back either';
    is $db->select( 'entitlement_past_due_invoices', 'invoice_id', { entitlement_id => $e->id } )->array->[0],
        'in_1', 'the failed invoice stays as history';
};

subtest 'past due counts from when the invoice failed' => sub {
    my $e = seat()->mark_past_due( $db, 'in_1', '2026-01-02T03:04:05Z' );
    is $db->query( 'SELECT past_due_since = ?::timestamptz FROM entitlements WHERE id = ?',
        '2026-01-02T03:04:05Z', $e->id )->array->[0], 1, 'past due since the failure Stripe reported';
};

done_testing;
