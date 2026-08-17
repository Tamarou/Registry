#!/usr/bin/env perl
# ABOUTME: Every whole-row write to a payment locks, refreshes, and refuses a settled row.
# ABOUTME: And the retrieval-failure branch settles inside a transaction, like the success branch.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Async qw( settle );
use Registry::DAO::Payment;
use Registry::Service::Stripe;
use Mojo::Promise;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_write_guards';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent = $dao->create(User => {
    username => 'wg_parent', name => 'WG Parent', user_type => 'parent',
    email => 'wg@test.local' });

sub a_payment ($status = 'pending') {
    my $p = Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => 10000, status => 'pending',
        metadata => { enrollment_items => [], tenant_slug => undef } });
    $db->update('payments',
        { status => $status, stripe_payment_intent_id => 'pi_wg_' . $p->id },
        { id => $p->id });
    return Registry::DAO::Payment->find($db, { id => $p->id });
}

sub row_of ($payment) { $db->select('payments', '*', { id => $payment->id })->hash }

# Load an object, then let another connection settle the row underneath it. The
# in-memory copy is now stale in exactly the way the decline-retry path produces:
# the cancel round trip to Stripe happens outside any transaction, so a webhook
# can complete the payment while this object is in hand.
sub stale_after_settlement ($status) {
    my $payment = a_payment('pending');
    my $stale   = Registry::DAO::Payment->find($db, { id => $payment->id });
    $db->update('payments', {
        status => $status, completed_at => \'NOW()',
        stripe_payment_intent_id => 'pi_wg_captured',
    }, { id => $payment->id });
    return $stale;
}

subtest 'recording an intent does not walk back a settled payment' => sub {
    # _record_intent stamps an intent id with a whole-row save(). From a stale
    # object that write also restores the old status, nulls completed_at, and
    # replaces the captured intent id with a fresh one -- after which the step
    # offers the parent a live card form for a payment already taken.
    for my $status (qw( completed refunded refund_pending )) {
        my $stale = stale_after_settlement($status);

        eval { $stale->_record_intent($db, { id => 'pi_wg_replacement',
                                             client_secret => 'cs_wg' }); 1 };

        my $row = row_of($stale);
        is $row->{status}, $status, "a $status payment keeps its status";
        ok defined $row->{completed_at}, "and keeps completed_at ($status)";
        is $row->{stripe_payment_intent_id}, 'pi_wg_captured',
            "and keeps the captured intent id ($status)";
    }
};

subtest 'recording an intent failure does not fail a settled payment' => sub {
    my $stale = stale_after_settlement('completed');

    eval { $stale->_record_intent_failure($db, 'card_declined'); 1 };

    is row_of($stale)->{status}, 'completed',
        'a captured payment is not marked failed by a later decline';
};

subtest 'rotating the idempotency token does not resurrect a settled payment' => sub {
    my $stale = stale_after_settlement('completed');

    eval { $stale->rotate_idempotency_token($db); 1 };

    my $row = row_of($stale);
    is $row->{status}, 'completed', 'the settled status survives a token rotation';
    ok defined $row->{completed_at}, 'and so does completed_at';
};

subtest 'a still-pending payment is unaffected by the guards' => sub {
    # The guards must not become "never write anything".
    my $payment = a_payment('pending');
    $payment->_record_intent($db, { id => 'pi_wg_new', client_secret => 'cs_wg_new' });
    is row_of($payment)->{stripe_payment_intent_id}, 'pi_wg_new',
        'a pending payment still records its intent';

    my $failing = a_payment('pending');
    eval { $failing->_record_intent_failure($db, 'boom'); 1 };
    is row_of($failing)->{status}, 'failed',
        'and a pending payment still records a failure';

    my $rotating = a_payment('pending');
    my $before   = row_of($rotating)->{metadata};
    $rotating->rotate_idempotency_token($db);
    isnt row_of($rotating)->{metadata}, $before,
        'and a pending payment still rotates its token';
};

subtest 'the retrieval-failure branch settles inside a transaction' => sub {
    # _record_retrieval_failure returns already_completed for a settled row, and
    # _settle_callback treats that exactly like success -- so the whole
    # settlement runs on this branch. The success branch opens a transaction;
    # this one must too, or the capacity re-check, the demotion and the debt
    # write all happen unprotected.
    my $payment = a_payment('completed');
    my $autocommit;

    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent_async =
        sub { Mojo::Promise->reject('connection reset by peer') };
    local *Registry::DAO::Payment::finalize_enrollment = sub ($self, $fdb) {
        $autocommit = $fdb->dbh->{AutoCommit} ? 1 : 0;
        return 0;
    };

    settle( $payment->process_payment_async( $db, 'pi_wg_boom',
        sub ($result) { $payment->finalize_enrollment($db); $result } ) );

    is $autocommit, 0,
        'the settlement on the failure branch runs inside a transaction';
};

done_testing;
