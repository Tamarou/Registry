#!/usr/bin/env perl
# ABOUTME: A posted payment intent must belong to this payment row and match its price.
# ABOUTME: And a row that never took money must not be refundable.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Payment;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_intent_ownership';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent = $dao->create(User => {
    username => 'io_parent', name => 'IO Parent', user_type => 'parent',
    email => 'io@test.local' });

sub a_payment ($cents) {
    my $p = Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => $cents, status => 'pending',
        metadata => { enrollment_items => [], tenant_slug => undef } });
    $db->update('payments', { stripe_payment_intent_id => 'pi_own_' . $p->id },
        { id => $p->id });
    return Registry::DAO::Payment->find($db, { id => $p->id });
}

sub status_of ($p) { $db->select('payments', ['status'], { id => $p->id })->hash->{status} }

# The posted intent id is client-controlled. Graded on its own, with no help
# from the amount guard: the foreign intent is priced EXACTLY like the target
# row, so the only thing that can refuse it is the ownership check.
subtest 'an intent belonging to another payment cannot settle this one' => sub {
    my $mine    = a_payment(200000);
    my $theirs  = a_payment(200000);

    my $forged = {
        id       => $theirs->stripe_payment_intent_id,
        status   => 'succeeded',
        amount   => 200000,
        metadata => { payment_id => $theirs->id },
    };

    my $out = $mine->_apply_intent($db, $forged, $forged->{id});

    is $out->{success}, 0, 'refused';
    like $out->{error}, qr/does not belong to this payment/,
        'and says why';
    is status_of($mine), 'pending',
        'the target row is untouched -- not completed';
    isnt status_of($mine), 'failed',
        'and a forged id cannot flip it to failed either';
    is $db->select('payments', ['stripe_payment_method_id'], { id => $mine->id })
        ->hash->{stripe_payment_method_id}, undef,
        'no payment method was copied across';
};

# Graded on its own: this intent IS owned, so ownership passes and only the
# amount comparison can refuse it. Without both subtests, either guard alone
# would keep the other's mutant alive.
subtest 'an owned intent for the wrong amount cannot settle the row' => sub {
    my $payment = a_payment(200000);

    my $stale = {
        id       => $payment->stripe_payment_intent_id,
        status   => 'succeeded',
        amount   => 500,
        metadata => { payment_id => $payment->id },
    };

    my $out = $payment->_apply_intent($db, $stale, $stale->{id});

    is $out->{success}, 0, 'refused';
    like $out->{error}, qr/amount does not match/, 'and says why';
    is status_of($payment), 'pending',
        'a mismatch is a refusal, not a payment failure';
};

subtest 'the matching case still settles, so the guards are not just always-refuse' => sub {
    my $payment = a_payment(200000);

    my $good = {
        id             => $payment->stripe_payment_intent_id,
        status         => 'succeeded',
        amount         => 200000,
        payment_method => 'pm_ok',
        metadata       => { payment_id => $payment->id },
    };

    my $out = $payment->_apply_intent($db, $good, $good->{id});

    is $out->{success}, 1, 'accepted';
    is status_of($payment), 'completed', 'and the row completed';
};

# The allow-list is the only thing stopping a Stripe refund against a row that
# never took money. Asserted by the die, before any network call is reachable.
subtest 'a payment that never took money cannot be refunded' => sub {
    for my $status (qw( pending processing failed )) {
        my $payment = a_payment(200000);
        $db->update('payments',
            { status => $status, metadata => { -json => { refund_owed_cents => 5000 } } },
            { id => $payment->id });
        my $fresh = Registry::DAO::Payment->find($db, { id => $payment->id });

        my $err = do { local $@; eval { $fresh->refund_async($db, { amount_cents => 5000 }) }; $@ };
        like $err, qr/Cannot refund a payment with status '$status'/,
            "a $status row refuses to refund";
    }
};

done_testing;
