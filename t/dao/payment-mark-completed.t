#!/usr/bin/env perl
# ABOUTME: mark_completed is the one way a payment reaches 'completed'.
# ABOUTME: Guards that the intent-recording writes are not it -- they stay pending and failed.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Payment;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_mark_completed';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent = $dao->create(User => {
    username => 'mc_parent', name => 'MC Parent', user_type => 'parent',
    email => 'mc@test.local',
});

sub fresh_payment () {
    return Registry::DAO::Payment->create($db, {
        user_id => $parent->id,
        amount_cents => 5000,
        status => 'pending',
        metadata => { enrollment_items => [], tenant_slug => undef },
    });
}

sub row_of ($payment) {
    return $db->select('payments', '*', { id => $payment->id })->hash;
}

subtest 'mark_completed sets status, intent id and completed_at together' => sub {
    my $payment = fresh_payment();
    is row_of($payment)->{completed_at}, undef, 'completed_at starts NULL';

    $payment->mark_completed($db, 'pi_mc_success');

    my $row = row_of($payment);
    is $row->{status}, 'completed', 'status is completed';
    is $row->{stripe_payment_intent_id}, 'pi_mc_success', 'intent id recorded';
    ok defined $row->{completed_at}, 'completed_at is stamped';
};

subtest 'recording an intent does not complete the payment' => sub {
    # The two intent-recording writes are on the same object as the completed
    # write and were once described as three call sites for mark_completed.
    # Following that literally completes a payment when its intent is created.
    my $payment = fresh_payment();

    $payment->_record_intent($db, {
        id => 'pi_mc_created', client_secret => 'cs_mc_created',
    });

    my $row = row_of($payment);
    is $row->{status}, 'pending', 'creating an intent leaves the payment pending';
    is $row->{completed_at}, undef, 'and stamps no completion time';
    is $row->{stripe_payment_intent_id}, 'pi_mc_created', 'but does record the intent id';
};

subtest 'a failed intent leaves the payment failed, not completed' => sub {
    my $payment = fresh_payment();

    eval { $payment->_record_intent_failure($db, 'card_declined'); 1 };

    my $row = row_of($payment);
    is $row->{status}, 'failed', 'a failed intent leaves the payment failed';
    is $row->{completed_at}, undef, 'and stamps no completion time';
    like $row->{error_message}, qr/card_declined/, 'the error is recorded';
};

done_testing;
