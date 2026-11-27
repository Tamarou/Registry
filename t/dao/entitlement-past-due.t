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

my $resource = Registry::DAO::Resource->create( $db, { name => 'Session seats', kind => 'finite', capacity => 10 } );
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
    is scalar $e->units( $db, $resource->id )->@*, 1, 'it holds its seat';
    ok $e->is_in_effect($db), 'and is in effect';
};

subtest 'paying the past due invoice clears it' => sub {
    my $e = seat();
    $e->mark_past_due( $db, 'in_1' );
    $e->clear_past_due( $db, 'in_1' );
    $e = reread($e);
    ok !$e->is_past_due, 'no longer past due';
    ok !defined $e->past_due_since && !defined $e->past_due_invoice_id, 'both columns cleared';
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

done_testing;
