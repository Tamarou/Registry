#!/usr/bin/env perl
# ABOUTME: A settlement holds the payment row it is deciding about.
# ABOUTME: And a run only reuses a payment row that is its own and still open.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Payment;
use Mojo::Pg;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_row_lock';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
my $uri     = $test_db->uri;

my $parent = $dao->create(User => {
    username => 'rl_parent', name => 'RL Parent', user_type => 'parent',
    email => 'rl@test.local',
});

sub payment_with ($status, %meta) {
    return Registry::DAO::Payment->create($db, {
        user_id => $parent->id,
        amount_cents => 5000,
        status => $status,
        metadata => { enrollment_items => [], tenant_slug => undef, %meta },
    });
}

# Can a second, independent connection take the row lock right now? NOWAIT turns
# "would block" into an immediate error, so this answers the question without
# hanging the test when the answer is no.
sub lockable_from_elsewhere ($payment_id) {
    my $other = Mojo::Pg->new($uri)->db;
    my $tx    = $other->begin;
    # Schema-qualified: a bare Mojo::Pg connection searches '"$user", public',
    # where payments does not exist, and an unqualified name here would fail for
    # that reason rather than for the lock -- reporting "not lockable" whether
    # the row was held or not.
    my $ok = eval {
        $other->query(
            'SELECT id FROM registry.payments WHERE id = ? FOR UPDATE NOWAIT',
            $payment_id);
        1;
    };
    return $ok ? 1 : 0;
}

subtest 'find with for => update holds the row for the rest of the transaction' => sub {
    my $payment = payment_with('pending');

    ok lockable_from_elsewhere($payment->id),
        'the row is free before anyone reads it';

    my $tx    = $db->begin;
    my $found = Registry::DAO::Payment->find($db, { id => $payment->id }, { for => 'update' });
    ok $found, 'the locking read still returns the row';

    is lockable_from_elsewhere($payment->id), 0,
        'a concurrent settlement cannot take the row while this one decides';

    undef $tx;    # rollback
    ok lockable_from_elsewhere($payment->id),
        'and the row is free again once the transaction ends';
};

subtest 'a plain find does not hold the row -- the lock is what closes the window' => sub {
    my $payment = payment_with('pending');

    my $tx    = $db->begin;
    my $found = Registry::DAO::Payment->find($db, { id => $payment->id });
    ok $found, 'the unlocked read returns the row too';

    ok lockable_from_elsewhere($payment->id),
        'but leaves it takeable -- two settlements can both read pending and both act';

    undef $tx;
};

subtest 'the reuse guard is an allow-list, not a deny-list of one' => sub {
    # ne 'completed' admitted every other status. A refunded row driven back
    # through the payment step would be reused and re-completed.
    for my $status (qw( refunded partially_refunded failed )) {
        my $payment = payment_with($status);
        ok !Registry::DAO::WorkflowSteps::Payment->_reusable_payment_row($payment, 'any-run'),
            "a $status row is not reusable";
    }

    for my $status (qw( pending processing )) {
        my $payment = payment_with($status, workflow_run_id => 'run-abc');
        ok Registry::DAO::WorkflowSteps::Payment->_reusable_payment_row($payment, 'run-abc'),
            "a $status row belonging to this run is reusable";
    }
};

subtest 'a payment row belonging to another run is not reusable' => sub {
    # workflow_run_id has been written on every payment since creation and never
    # read back. Status alone cannot tell these apart: both are pending.
    my $mine   = payment_with('pending', workflow_run_id => 'run-mine');
    my $theirs = payment_with('pending', workflow_run_id => 'run-theirs');

    ok Registry::DAO::WorkflowSteps::Payment->_reusable_payment_row($mine, 'run-mine'),
        'my own pending row is reusable';
    ok !Registry::DAO::WorkflowSteps::Payment->_reusable_payment_row($theirs, 'run-mine'),
        'another run\'s pending row is refused on ownership, not on status';

    my $unstamped = payment_with('pending');
    ok !Registry::DAO::WorkflowSteps::Payment->_reusable_payment_row($unstamped, 'run-mine'),
        'a row predating the stamp is refused rather than assumed to be ours';
};

done_testing;
