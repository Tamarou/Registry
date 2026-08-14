#!/usr/bin/env perl
# ABOUTME: A superseded PaymentIntent must not demote an already-completed payment.
# ABOUTME: Ownership alone cannot tell them apart -- every intent carries our payment_id.
use 5.42.0;
use warnings;
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Payment;
use Registry::Service::Stripe;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $user_id = $db->query(q{
    INSERT INTO registry.users (username, passhash)
    VALUES ('stale_intent_replay', 'nohash')
    RETURNING id
})->hash->{id};

# A payment row that Stripe has already captured, via pi_second. pi_first is the
# earlier intent that was cancelled when the first attempt declined -- the shape
# the parent's browser still holds in its history after a 3DS attempt fails.
sub captured_payment () {
    my $payment = Registry::DAO::Payment->create( $db, {
        user_id  => $user_id,
        amount_cents => 15000,
        metadata => {},
    } );
    $payment->update( $db, { stripe_payment_intent_id => 'pi_second' } );

    my $reloaded = Registry::DAO::Payment->find( $db, { id => $payment->id } );

    no warnings qw(redefine once);
    local *Registry::Service::Stripe::retrieve_payment_intent = sub {
        return {
            id             => 'pi_second',
            status         => 'succeeded',
            amount         => 15_000,
            payment_method => 'pm_card_visa',
            metadata       => { payment_id => $reloaded->id },
        };
    };
    my $result = $reloaded->process_payment( $db, 'pi_second' );
    ok $result->{success}, 'setup: pi_second captured the payment';

    return Registry::DAO::Payment->find( $db, { id => $reloaded->id } );
}

# Both terminal states the decline branch acts on. 'canceled' is the intent the
# retry path cancelled; 'requires_payment_method' is the same intent when that
# best-effort cancel failed and the error was swallowed.
for my $stale_status (qw(canceled requires_payment_method)) {
    subtest "a stale $stale_status intent cannot demote a captured payment" => sub {
        my $payment = captured_payment();
        is $payment->status, 'completed', 'payment starts completed';

        no warnings qw(redefine once);
        local *Registry::Service::Stripe::retrieve_payment_intent = sub {
            return {
                id       => 'pi_first',
                status   => $stale_status,
                # Every intent minted for this row is stamped with our
                # payment_id, so the superseded one passes the ownership check.
                metadata => { payment_id => $payment->id },
            };
        };

        my $result = $payment->process_payment( $db, 'pi_first' );

        ok !$result->{success}, 'the stale intent does not report success';
        ok $result->{already_completed},
            'caller is told the row was already completed, not that it failed';
        ok !defined $result->{intent_status},
            'no intent_status, so the decline branch cannot mint a replacement';

        my $reloaded = Registry::DAO::Payment->find( $db, { id => $payment->id } );
        is $reloaded->status, 'completed',
            'captured payment is still completed';
        is $reloaded->stripe_payment_intent_id, 'pi_second',
            'the capturing intent is still the one on record';
    };
}

subtest 'the current intent still completes a pending payment' => sub {
    # The guard must not block the ordinary first settlement.
    my $payment = Registry::DAO::Payment->create( $db, {
        user_id  => $user_id,
        amount_cents => 4200,
        metadata => {},
    } );
    $payment->update( $db, { stripe_payment_intent_id => 'pi_only' } );
    my $reloaded = Registry::DAO::Payment->find( $db, { id => $payment->id } );

    no warnings qw(redefine once);
    local *Registry::Service::Stripe::retrieve_payment_intent = sub {
        return {
            id             => 'pi_only',
            status         => 'succeeded',
            amount         => 4_200,
            payment_method => 'pm_card_visa',
            metadata       => { payment_id => $reloaded->id },
        };
    };

    ok $reloaded->process_payment( $db, 'pi_only' )->{success},
        'a pending payment still completes normally';
};

subtest 'a genuine decline on a pending payment still reports intent_status' => sub {
    # The decline branch depends on intent_status to decide whether to mint a
    # replacement intent; the guard must not suppress it for real declines.
    my $payment = Registry::DAO::Payment->create( $db, {
        user_id  => $user_id,
        amount_cents => 9900,
        metadata => {},
    } );
    $payment->update( $db, { stripe_payment_intent_id => 'pi_declined' } );
    my $reloaded = Registry::DAO::Payment->find( $db, { id => $payment->id } );

    no warnings qw(redefine once);
    local *Registry::Service::Stripe::retrieve_payment_intent = sub {
        return {
            id       => 'pi_declined',
            status   => 'requires_payment_method',
            metadata => { payment_id => $reloaded->id },
            last_payment_error => { message => 'Your card was declined.' },
        };
    };

    my $result = $reloaded->process_payment( $db, 'pi_declined' );
    ok !$result->{success}, 'declined payment does not succeed';
    is $result->{intent_status}, 'requires_payment_method',
        'intent_status still surfaced so the retry path can run';
    is Registry::DAO::Payment->find( $db, { id => $reloaded->id } )->status,
        'failed', 'a real decline still marks the payment failed';
};

done_testing();
