#!/usr/bin/env perl
# ABOUTME: Every single-row payment write carries its own legality in the WHERE clause.
# ABOUTME: Zero rows is the refusal -- not a return shape a caller can misread.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Payment;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_conditional_write';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent = $dao->create(User => {
    username => 'cw_parent', name => 'CW Parent', user_type => 'parent',
    email => 'cw@test.local' });

my $n = 0;
sub a_payment ($status = 'pending') {
    $n++;
    my $p = Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => 10000, status => 'pending',
        metadata => { enrollment_items => [], tenant_slug => undef } });
    $db->update('payments',
        { status => $status, stripe_payment_intent_id => "pi_cw_$n" },
        { id => $p->id });
    return Registry::DAO::Payment->find($db, { id => $p->id });
}
sub status_of ($p) {
    $db->select('payments', ['status'], { id => $p->id })->hash->{status}
}

# The graph is the single place a state is added, and every status write builds
# its WHERE from it. Asserted directly so a caller cannot quietly grow its own
# opinion -- which is how this path accumulated two classifiers that disagreed.
subtest 'the transition graph is the one source of legality' => sub {
    my $g = Registry::DAO::Payment->_legal_predecessors;

    is ref $g, 'HASH', 'it is a table, not scattered literals';
    is_deeply [ sort keys %$g ],
        [ sort qw( processing completed failed refund_pending refunded partially_refunded ) ],
        'covering every status the code writes';

    # Every status named as a predecessor must itself be a status the CHECK
    # permits, or the graph describes transitions the database refuses.
    my $allowed = $db->query(q{
        SELECT pg_get_constraintdef(oid) FROM pg_constraint
         WHERE conname = 'payments_status_check'})->array->[0];
    my %in_db = map { $_ => 1 } ( $allowed =~ /'([a-z_]+)'::/g );
    for my $to ( sort keys %$g ) {
        my @unknown = grep { !$in_db{$_} } @{ $g->{$to} };
        is scalar @unknown, 0, "every predecessor of '$to' is a real status";
    }
};

# The point of the whole design: a write that is not legal moves nothing, and
# says so by touching zero rows rather than by a return value shaped like
# success.
subtest 'an illegal transition is refused, and the refusal is unambiguous' => sub {
    # completed <- pending|processing only. A refunded row must not be walked back.
    for my $from (qw( refunded partially_refunded refund_pending completed failed )) {
        my $p = a_payment($from);
        ok !$p->mark_completed( $db, 'pi_walkback' ),
            "mark_completed refuses a '$from' row, and reports the refusal";
        is status_of($p), $from, "and '$from' is left alone";
    }

    for my $from (qw( pending processing )) {
        my $p = a_payment($from);
        ok $p->mark_completed( $db, 'pi_ok' ), "mark_completed accepts '$from'";
        is status_of($p), 'completed', "and '$from' reaches completed";
    }
};

subtest 'a completed row cannot be failed by a later decline' => sub {
    my $p = a_payment('completed');
    ok !$p->_record_intent_failure_write( $db, 'card_declined' ),
        'the failure write is refused';
    is status_of($p), 'completed', 'and the captured payment stands';

    my $q = a_payment('pending');
    ok $q->_record_intent_failure_write( $db, 'card_declined' ),
        'while a pending row does fail';
    is status_of($q), 'failed', 'and reaches failed';
};

# The columns a write does not name must survive it. save() wrote six columns
# from the in-memory object, so any stale field silently restored an old value.
subtest 'a write touches only the columns it names' => sub {
    my $p = a_payment('pending');
    $db->update('payments', {
        error_message => 'set by someone else',
        metadata      => { -json => { keep => 'me', enrollment_items => [] } },
    }, { id => $p->id });

    $p->mark_completed( $db, 'pi_narrow' );

    my $row = $db->select('payments', '*', { id => $p->id })->expand->hash;
    is $row->{status}, 'completed', 'the named column changed';
    is $row->{error_message}, 'set by someone else',
        'and a column it does not name is not restored from a stale object';
    is $row->{metadata}{keep}, 'me', 'nor is the metadata blob rewritten';
};

done_testing;
