#!/usr/bin/env perl
# ABOUTME: Once money has moved for a payment, nothing re-decides it.
# ABOUTME: A refunded row is not re-completed, and a transport blip does not fail a paid one.
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

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_settled_state';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent = $dao->create(User => {
    username => 'ssm_parent', name => 'SSM Parent', user_type => 'parent',
    email => 'ssm@test.local',
});

sub payment_with ($status) {
    my $p = Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => 10000, status => 'pending',
        metadata => { enrollment_items => [], tenant_slug => undef },
    });
    $db->update('payments', {
        status => $status, stripe_payment_intent_id => 'pi_ssm_' . $p->id,
    }, { id => $p->id });
    return Registry::DAO::Payment->find($db, { id => $p->id });
}

sub succeeded_intent ($payment) {
    return {
        id => 'pi_ssm_' . $payment->id, status => 'succeeded', amount => 10000,
        payment_method => 'pm_ssm', metadata => { payment_id => $payment->id },
    };
}

sub status_of ($payment) {
    Registry::DAO::Payment->find($db, { id => $payment->id })->status;
}

# Drive a real settlement with only the network faked, so _apply_intent and the
# status guards are the code under test rather than a Stripe retrieval that
# would fail on the placeholder key and land in the failure branch regardless.
sub settle_with_succeeded_intent ($payment) {
    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent_async =
        sub { Mojo::Promise->resolve( succeeded_intent($payment) ) };
    return settle( $payment->process_payment_async($db, 'pi_ssm_' . $payment->id) );
}

# Money has moved for these four. A later settlement of the same payment --
# a Stripe redelivery, a bookmarked return URL, an operator re-driving a run --
# must not walk any of them back to 'completed'.
my @MONEY_MOVED = qw( completed refunded partially_refunded refund_pending );

subtest 'a settlement does not re-complete a payment whose money already moved' => sub {
    for my $status (@MONEY_MOVED) {
        my $payment = payment_with($status);
        my $result  = settle_with_succeeded_intent($payment);

        is status_of($payment), $status,
            "a $status payment is left $status by a second settlement";
        ok $result->{already_completed} || $result->{success},
            "and the caller is told to carry on, not shown an error ($status)";
    }
};

subtest 'a refunded payment is not re-completed and does not owe again' => sub {
    # The sequence that produces a double refund: capacity gate refunds, then a
    # redelivery arrives with a different event id, the dedup claim lets it
    # through, and the row is driven back to completed and demoted again.
    my $payment = payment_with('refunded');
    $db->update('payments', {
        metadata => { -json => { enrollment_items => [], tenant_slug => undef,
                                 refund_owed_cents => 10000 } },
    }, { id => $payment->id });

    my $reloaded = Registry::DAO::Payment->find($db, { id => $payment->id });
    settle_with_succeeded_intent($reloaded);

    is status_of($payment), 'refunded', 'the refunded row stays refunded';
};

subtest 'a transport failure does not downgrade a payment whose money moved' => sub {
    # _record_retrieval_failure writes status = 'failed' unconditionally. On a
    # row another settlement already completed, that leaves a live enrollment
    # against a failed payment.
    for my $status (@MONEY_MOVED) {
        my $payment = payment_with($status);

        no warnings 'redefine';
        local *Registry::Service::Stripe::retrieve_payment_intent_async =
            sub { Mojo::Promise->reject('connection reset by peer') };

        eval { settle( $payment->process_payment_async($db, 'pi_ssm_boom') ); 1 };

        is status_of($payment), $status,
            "a Stripe blip leaves a $status payment alone";
    }
};

subtest 'a genuinely pending payment still settles and still fails' => sub {
    # The guards must not become "never write anything".
    my $ok = payment_with('pending');
    settle_with_succeeded_intent($ok);
    is status_of($ok), 'completed', 'a pending payment still completes';

    my $bad = payment_with('pending');
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::retrieve_payment_intent_async =
            sub { Mojo::Promise->reject('connection reset by peer') };
        eval { settle( $bad->process_payment_async($db, 'pi_ssm_boom2') ); 1 };
    }
    is status_of($bad), 'failed', 'and a pending payment still records a failure';
};

done_testing;
