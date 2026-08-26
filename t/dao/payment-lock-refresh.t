#!/usr/bin/env perl
# ABOUTME: Locking a payment row re-reads every field save() will write back.
# ABOUTME: Otherwise a settlement clobbers what another settlement committed while it waited on Stripe.
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

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_lock_refresh';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent = $dao->create(User => {
    username => 'lr_parent', name => 'LR Parent', user_type => 'parent',
    email => 'lr@test.local',
});

sub a_payment () {
    my $p = Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => 10000, status => 'pending',
        metadata => { enrollment_items => [], tenant_slug => undef },
    });
    $db->update('payments', { stripe_payment_intent_id => 'pi_lr_' . $p->id },
        { id => $p->id });
    return Registry::DAO::Payment->find($db, { id => $p->id });
}

sub row_of ($payment) {
    $db->select('payments', '*', { id => $payment->id })->expand->hash;
}

# The interleaving this guards: an object is loaded, the settlement goes out to
# Stripe, another settlement commits something to the same row in the meantime,
# and then the first one's save() writes all six of its columns back from an
# object that predates that commit.
sub settle_after_concurrent_write ($payment, $writer) {
    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent_async = sub {
        $writer->();    # commits while this settlement is "on the network"
        return Mojo::Promise->resolve({
            id => 'pi_lr_' . $payment->id, status => 'succeeded', amount => 10000,
            payment_method => 'pm_lr', metadata => { payment_id => $payment->id },
        });
    };
    return settle( $payment->process_payment_async($db, 'pi_lr_' . $payment->id) );
}

subtest 'a concurrent manual-review flag survives this settlement save' => sub {
    # Retained as a regression guard on the CONDITIONAL writes: none of them
    # names metadata, so a flag written concurrently must survive. save() -- the
    # whole-row write this once guarded against -- is gone, and if a future
    # writer starts naming metadata again this is what notices. This used to seed refund_owed_cents, which no longer lives in
    # metadata -- the assertion still passed but graded nothing. The flag is
    # what save() can still destroy, and losing it loses the only record that a
    # share needs a human.
    my $payment = a_payment();

    settle_after_concurrent_write($payment, sub {
        $db->query(
            q{UPDATE payments SET metadata = metadata || ?::jsonb WHERE id = ?},
            '{"refund_manual_review":[{"child_id":"kid-x"}]}', $payment->id );
    });

    is_deeply row_of($payment)->{metadata}{refund_manual_review},
        [ { child_id => 'kid-x' } ],
        'the flag another settlement recorded is still there';
};

subtest 'a concurrently rotated intent id is not written back stale' => sub {
    # The decline-retry path rotates the intent id. A settlement holding the
    # superseded one must not restore it, or the row points at a cancelled
    # intent.
    my $payment = a_payment();

    settle_after_concurrent_write($payment, sub {
        $db->update('payments', { stripe_payment_intent_id => 'pi_lr_rotated' },
            { id => $payment->id });
    });

    isnt row_of($payment)->{stripe_payment_intent_id}, 'pi_lr_' . $payment->id,
        'the superseded intent id is not restored over the rotated one';
};

subtest 'a concurrently recorded error message is not resurrected' => sub {
    my $payment = a_payment();
    $db->update('payments', { error_message => 'earlier failure' },
        { id => $payment->id });
    my $stale = Registry::DAO::Payment->find($db, { id => $payment->id });

    settle_after_concurrent_write($stale, sub {
        $db->update('payments', { error_message => undef }, { id => $payment->id });
    });

    is row_of($payment)->{error_message}, undef,
        'a cleared error stays cleared rather than being written back';
};

subtest 'the refresh does not break an ordinary settlement' => sub {
    my $payment = a_payment();
    settle_after_concurrent_write($payment, sub { });

    my $row = row_of($payment);
    is $row->{status}, 'completed', 'the payment still completes';
    ok defined $row->{completed_at}, 'and is still stamped';
};

done_testing;
