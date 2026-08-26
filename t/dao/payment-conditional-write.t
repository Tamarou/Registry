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
    is_deeply [ sort keys %$g ], [ sort qw( processing completed failed ) ],
        'covering the intent path, and claiming no more than that';

    # Deliberately NOT the refund statuses. Their writers carry headroom and
    # increment predicates this table cannot express, and an earlier version
    # listed them anyway -- unconsulted, and contradicting those writers in four
    # of six cases. A table half documentation and half false is worse than a
    # smaller true one, in the place a future author will trust.
    my @refund_states = qw( refund_pending refunded partially_refunded );
    is scalar( grep { exists $g->{$_} } @refund_states ), 0,
        'and not claiming authority over the refund writers it does not govern';

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
    for my $from (qw( refunded partially_refunded refund_pending completed )) {
        my $p = a_payment($from);
        ok !$p->mark_completed( $db, 'pi_walkback' ),
            "mark_completed refuses a '$from' row, and reports the refusal";
        is status_of($p), $from, "and '$from' is left alone";
    }

    # 'failed' belongs here, not above. _apply_intent writes 'failed' for any
    # intent status it does not recognise -- including requires_action, which is
    # an ordinary 3DS payment mid-authentication -- and the decline-retry path
    # deliberately reuses the same row. Both then legitimately reach completed
    # when the money lands, and refusing that strands a CAPTURED payment at
    # 'failed' with completed_at NULL and _refundable_status false: unrefundable
    # forever, while finalize_enrollment still seats the child.
    for my $from (qw( pending processing failed )) {
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

# The columns save() used to carry that the conditional writes must not drop.
subtest 'completing a payment records the method it was paid with' => sub {
    my $p = a_payment('pending');
    $db->update('payments', { stripe_payment_method_id => undef }, { id => $p->id });

    $p->mark_completed( $db, 'pi_pm', 'pm_card_visa' );

    is $db->select('payments', ['stripe_payment_method_id'], { id => $p->id })
        ->hash->{stripe_payment_method_id}, 'pm_card_visa',
        'the payment method is written -- save() carried this column and the '
        . 'first conversion dropped it silently';
};

# A refusal the caller discards is a caller reporting success for work that did
# not happen.
subtest 'a refused completion is reported to the caller, not swallowed' => sub {
    my $p = a_payment('refunded');
    my $out = $p->_apply_intent( $db,
        { id => 'pi_refused', status => 'succeeded', amount => 10000,
          metadata => { payment_id => $p->id } },
        'pi_refused' );

    ok !$out->{success}, 'the caller is told the settlement did not happen';
    is status_of($p), 'refunded', 'and the row is untouched';
};

# Each decline must record its own reason. failed -> failed being illegal left
# the second decline showing the first one's message.
subtest 'a second decline records its own error, not the first one' => sub {
    my $p = a_payment('pending');
    $p->_record_intent_failure_write( $db, 'insufficient_funds' );
    $p->_record_intent_failure_write( $db, 'expired_card' );

    is $db->select('payments', ['error_message'], { id => $p->id })->hash->{error_message},
        'expired_card',
        'the parent is shown the card that just failed, not the previous one';
};

# The two routes that reach mark_completed from 'failed'. Neither was graded,
# which is how a conversion that refuses both passed nineteen payment files.
subtest '3DS: a row written failed by requires_action still completes' => sub {
    my $p = a_payment('pending');

    # _apply_intent writes 'failed' for any status it does not recognise, and
    # requires_action is an ordinary 3DS payment mid-authentication.
    my $out = $p->_apply_intent( $db,
        { id => 'pi_3ds', status => 'requires_action', amount => 10000,
          metadata => { payment_id => $p->id } }, 'pi_3ds' );
    ok !$out->{success}, 'the intent is not settled yet';
    is status_of($p), 'failed', 'and the row is written failed (pre-existing)';

    # The parent authenticates off-site and Stripe fires payment_intent.succeeded.
    my $fresh = Registry::DAO::Payment->find($db, { id => $p->id });
    ok $fresh->mark_completed( $db, 'pi_3ds', 'pm_3ds' ),
        'the later webhook completes it';
    is status_of($p), 'completed',
        'so a captured 3DS charge is not stranded at failed, unrefundable';
};

subtest 'decline then retry: the reused row still completes' => sub {
    my $p = a_payment('pending');
    $p->_record_intent_failure_write( $db, 'card_declined' );
    is status_of($p), 'failed', 'the decline is recorded';

    # WorkflowSteps/Payment reuses the same row rather than orphaning it.
    my $fresh = Registry::DAO::Payment->find($db, { id => $p->id });
    ok $fresh->mark_completed( $db, 'pi_retry', 'pm_good_card' ),
        'the good card completes the same row';
    is status_of($p), 'completed', 'and the parent is not charged into a failed row';
};

subtest 'a retry that goes to processing is not reported against a refused write' => sub {
    my $p = a_payment('failed');
    my $out = $p->_apply_intent( $db,
        { id => 'pi_proc', status => 'processing', amount => 10000,
          metadata => { payment_id => $p->id } }, 'pi_proc' );

    is status_of($p), 'processing',
        'the row really moves, so "please wait" is not shown against a dead row';
    ok $out->{processing}, 'and the caller is told to wait';
};

# Eight of eighteen mutants survived the first pass here. These are them.
#
# The in-memory field updates were entirely ungraded: a writer could stop
# refreshing $status and nothing noticed, leaving the object disagreeing with
# the row it just wrote -- and callers read those fields to decide what to do
# next.
subtest 'a successful write leaves the object agreeing with the row' => sub {
    my $p = a_payment('pending');
    $p->mark_completed( $db, 'pi_mem', 'pm_mem' );
    is $p->status, 'completed', 'mark_completed refreshes the status it wrote';
    is $p->stripe_payment_intent_id, 'pi_mem', 'and the intent id';
    is $p->stripe_payment_method_id, 'pm_mem', 'and the payment method';

    my $q = a_payment('pending');
    $q->_record_intent_failure_write( $db, 'declined_here' );
    is $q->status, 'failed', 'the failure writer refreshes its status';
    is $q->error_message, 'declined_here', 'and its message';

    my $r = a_payment('pending');
    $r->_record_processing($db);
    is $r->status, 'processing', 'and the processing writer refreshes its status';

    my $t = a_payment('pending');
    $t->_record_intent_id( $db, 'pi_stamped' );
    is $t->stripe_payment_intent_id, 'pi_stamped', 'as does the intent stamp';
};

# A refused write must NOT refresh the object -- that is how a caller comes to
# believe a transition happened that the database rejected.
subtest 'a refused write leaves the object alone' => sub {
    my $p = a_payment('refunded');
    $p->mark_completed( $db, 'pi_no', 'pm_no' );
    is $p->status, 'refunded', 'the object still reports what the row holds';
    isnt $p->stripe_payment_intent_id, 'pi_no', 'and did not take the refused id';
};

# _record_processing was new in this change and had no coverage of either its
# predicate or its write.
subtest 'processing is reachable only from pending or failed' => sub {
    for my $from (qw( pending failed )) {
        my $p = a_payment($from);
        ok $p->_record_processing($db), "'$from' may move to processing";
        is status_of($p), 'processing', "and '$from' does";
    }
    for my $from (qw( completed refunded partially_refunded )) {
        my $p = a_payment($from);
        ok !$p->_record_processing($db), "'$from' may not";
        is status_of($p), $from, "and '$from' is untouched";
    }
};

# rotate_idempotency_token's settled guard had no test at all: deleting it let a
# completed row rotate its token, and the file that claims to grade this asserts
# only columns rotate does not write.
subtest 'a settled payment does not rotate its idempotency token' => sub {
    for my $status (qw( completed refunded partially_refunded refund_pending )) {
        my $p = a_payment($status);
        my $before = $db->select('payments', ['metadata'], { id => $p->id })
            ->expand->hash->{metadata}{idempotency_token};

        ok !$p->rotate_idempotency_token($db),
            "a '$status' row refuses to rotate, and says so";
        is $db->select('payments', ['metadata'], { id => $p->id })
            ->expand->hash->{metadata}{idempotency_token}, $before,
            "and its token is unchanged ($status)";
    }

    my $p = a_payment('pending');
    my $before = $db->select('payments', ['metadata'], { id => $p->id })
        ->expand->hash->{metadata}{idempotency_token};
    my $token = $p->rotate_idempotency_token($db);
    ok $token, 'a pending row rotates and returns the new token';
    isnt $token, $before, 'which is actually new';
};

done_testing;
