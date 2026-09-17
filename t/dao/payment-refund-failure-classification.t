#!/usr/bin/env perl
# ABOUTME: A failed refund says whether anything was ever sent to Stripe.
# ABOUTME: "Nothing was sent" is knowable with certainty and spares the operator a reconciliation.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Async qw( settle );
use Registry::DAO::Payment;
use Mojo::Promise;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_refund_classification';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent = $dao->create(User => {
    username => 'rfc_parent', name => 'RFC Parent', user_type => 'parent',
    email => 'rfc@test.local',
});

sub a_payment ( %overrides ) {
    my $p = Registry::DAO::Payment->create($db, {
        user_id      => $parent->id,
        amount_cents => 15000,
        status       => $overrides{status} // 'refund_pending',
        metadata     => { enrollment_items => [], tenant_slug => undef },
    });
    $db->update('payments',
        { stripe_payment_intent_id => $overrides{intent} },
        { id => $p->id });
    return Registry::DAO::Payment->find($db, { id => $p->id });
}

# Started from a resolved promise, as both production callers do. refund_async
# raises its pre-dispatch guards synchronously, so a bare ->catch on the
# returned promise never sees them -- the exception escapes the caller instead.
sub refund_error ( $payment ) {
    my $err;
    settle(
        Mojo::Promise->resolve->then( sub {
            $payment->refund_async( $db,
                { amount_cents => 100, idempotency_key => 'key_rfc' } );
        } )->catch( sub { $err = shift } )
    );
    return $err // '';
}

# The runbook's procedure is to list refunds from Stripe before issuing one,
# because the row cannot say whether money moved. For these two it can: nothing
# was dispatched, so nothing moved, and the listing step is wasted work.
subtest 'a refund that never reached Stripe says so' => sub {
    my $no_intent = a_payment( intent => undef );
    is Registry::DAO::Payment->classify_refund_failure( refund_error($no_intent) ),
        'not_sent', 'a missing payment intent id';

    my $wrong_status = a_payment( status => 'pending', intent => 'pi_rfc_status' );
    is Registry::DAO::Payment->classify_refund_failure( refund_error($wrong_status) ),
        'not_sent', 'a status the refund guard refuses';
};

# Everything past the dispatch. A Stripe error response and a lost response are
# not distinguishable here, and claiming otherwise would be worse than saying
# nothing: the operator would skip a reconciliation that money may need.
subtest 'anything else is reported as unknown, not guessed at' => sub {
    is Registry::DAO::Payment->classify_refund_failure('Stripe api_error: service unavailable'),
        'unknown', 'a Stripe error response';
    is Registry::DAO::Payment->classify_refund_failure('Premature connection close'),
        'unknown', 'a transport failure';
    is Registry::DAO::Payment->classify_refund_failure(''),
        'unknown', 'and an empty error is not mistaken for certainty';
};

# The log is where an operator looks second. The row is where the runbook looks
# first, so the classification has to survive on it.
subtest 'the payment records its last refund failure' => sub {
    my $payment = a_payment( intent => undef );
    my $err     = refund_error($payment);

    $payment->record_refund_failure( $db, $err );

    my $stamped = Registry::DAO::Payment->find($db, { id => $payment->id })
        ->metadata->{refund_last_failure};

    ok $stamped, 'a record is written';
    is $stamped->{classification}, 'not_sent', 'carrying the classification';
    like $stamped->{message}, qr/payment intent/i, 'and the reason';
    ok $stamped->{at}, 'and when';
};

done_testing;
