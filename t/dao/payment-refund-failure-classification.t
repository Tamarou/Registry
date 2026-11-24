#!/usr/bin/env perl
# ABOUTME: A failed refund says whether anything was ever sent to Stripe.
# ABOUTME: "Nothing was sent" is knowable with certainty and spares the operator a reconciliation.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Async qw( settle );
use Test::Registry::Fixtures;
use Registry::DAO::Payment;
use Registry::Service::Stripe;
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


# Stripe answers some refunds 'pending' (bank-backed methods, some cards): the
# money has not moved yet and may never, so the row must not say it has.
subtest 'pending refund is not recorded as completed' => sub {
    my $seller = Test::Registry::Fixtures::platform_seller($db);
    my $payment = Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => 15000, status => 'completed',
        stripe_payment_intent_id => 'pi_rfc_pending',
        metadata => { enrollment_items => [], tenant_slug => $seller } });

    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_refund_async = sub ($s, $params) {
            Mojo::Promise->resolve({ id => 're_pending', status => 'pending' });
        };
        settle( $payment->refund_async($db) );
    }

    my $row = $db->select('payments', '*', { id => $payment->id })->expand->hash;
    is $row->{status}, 'completed', 'the payment is not marked refunded';
    is $row->{refunded_cents}, 0, 'nothing is recorded as returned';
    is $row->{metadata}{refund_id}, 're_pending', 'the refund is on record';
    is $row->{metadata}{refund_status}, 'pending', 'as pending';
};

# Stripe can answer a refund already failed or canceled. No money went back,
# so nothing may count it, and a retry under the same key must not be told the
# refund succeeded.
subtest 'a refund Stripe returns failed or canceled is not counted' => sub {
    my $seller = Test::Registry::Fixtures::platform_seller($db);
    for my $answer (qw( failed canceled )) {
        my $payment = Registry::DAO::Payment->create($db, {
            user_id => $parent->id, amount_cents => 15000, status => 'completed',
            stripe_payment_intent_id => "pi_rfc_$answer",
            metadata => { enrollment_items => [], tenant_slug => $seller } });

        my $calls = 0;
        my $err;
        {
            no warnings 'redefine';
            local *Registry::Service::Stripe::create_refund_async = sub ($s, $params) {
                $calls++;
                Mojo::Promise->resolve({ id => "re_$answer", status => $answer });
            };
            for (1, 2) {
                undef $err;
                settle( $payment->refund_async( $db,
                    { amount_cents => 5000, idempotency_key => "key_rfc_$answer" } )
                    ->catch( sub { $err = shift } ) );
            }
        }

        my $row = $db->select('payments', '*', { id => $payment->id })->expand->hash;
        is $row->{status}, 'completed', "$answer: the payment is not marked refunded";
        is $row->{refunded_cents}, 0, "$answer: nothing is recorded as returned";
        is $row->{metadata}{refund_status}, $answer, "$answer: the refund is recorded as $answer";
        like $err // '', qr/\Q$answer\E/, "$answer: the caller is told the refund did not go through";
        is $calls, 2, "$answer: a retry under the same key is not answered as succeeded";
    }
};

# A retry of a refund still pending under its key: the capacity loop and a
# re-run drop step both do this. Resending replays "pending" inside Stripe's 24h
# key window and, past it, creates a second real refund beside the first.
subtest 'a refund still pending under its key is not resent' => sub {
    my $seller = Test::Registry::Fixtures::platform_seller($db);
    my $payment = Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => 15000, status => 'completed',
        stripe_payment_intent_id => 'pi_rfc_held',
        metadata => { enrollment_items => [], tenant_slug => $seller } });

    my $calls = 0;
    my @got;
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_refund_async = sub ($s, $params) {
            $calls++;
            Mojo::Promise->resolve({ id => 're_held', status => 'pending' });
        };
        for (1, 2) {
            settle( $payment->refund_async( $db,
                { amount_cents => 5000, idempotency_key => 'key_rfc_held' } )
                ->then( sub { push @got, shift } ) );
        }
    }

    is $calls, 1, 'Stripe is asked once';
    is $got[1]{id}, 're_held', 'the retry gets the held refund back';
    is $got[1]{status}, 'pending', 'still pending';
};

# Within the 24h key window Stripe replays the original "pending" answer for a
# refund that has since failed. Holding it again would wait forever on a
# refund.updated that already came.
subtest 'a replayed refund already recorded as failed is rejected' => sub {
    my $seller = Test::Registry::Fixtures::platform_seller($db);
    my $payment = Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => 15000, status => 'completed',
        stripe_payment_intent_id => 'pi_rfc_replay',
        metadata => { enrollment_items => [], tenant_slug => $seller } });

    my $err;
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_refund_async = sub ($s, $params) {
            Mojo::Promise->resolve({ id => 're_replay', status => 'pending' });
        };
        settle( $payment->refund_async( $db,
            { amount_cents => 5000, idempotency_key => 'key_rfc_replay' } ) );
        $payment->settle_pending_refund( $db, { id => 're_replay', status => 'failed' } );
        settle( $payment->refund_async( $db,
            { amount_cents => 5000, idempotency_key => 'key_rfc_replay' } )
            ->catch( sub { $err = shift } ) );
    }

    like $err // '', qr/re_replay.*failed/, 'the caller is told it failed';
    my $row = $db->select('payments', '*', { id => $payment->id })->expand->hash;
    ok !exists $row->{metadata}{pending_refunds}{re_replay}, 'and it is not held again';
};

done_testing;
