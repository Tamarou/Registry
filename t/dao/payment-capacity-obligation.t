#!/usr/bin/env perl
# ABOUTME: A capacity obligation accumulates, stays findable, and is never re-adjudicated.
# ABOUTME: Every subtest here reproduces a defect a review round found in the first attempt.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Payment;
use Registry::DAO::Enrollment;
use Registry::DAO::Family;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_capacity_obligation';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $loc = $dao->create(Location => {
    name => 'OB Studio', slug => 'ob-studio', address_info => {}, metadata => {} });
my $prog = $dao->create(Project => {
    status => 'published', name => 'OB Camp',
    program_type_slug => 'summer-camp', metadata => {} });
my $teacher = $dao->create(User => {
    username => 'ob_teacher', name => 'T', user_type => 'staff',
    email => 'obt@test.local' });
my $parent = $dao->create(User => {
    username => 'ob_parent', name => 'OB Parent', user_type => 'parent',
    email => 'ob@test.local' });

my $seq = 0;
sub a_child () {
    $seq++;
    Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => "OB Kid $seq", birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' } });
}
sub a_session ($capacity) {
    $seq++;
    my $s = $dao->create(Session => {
        name => "OB Week $seq", start_date => '2026-01-01', end_date => '2026-12-31',
        status => 'published', capacity => $capacity, metadata => {} });
    my $e = $dao->create(Event => {
        time => sprintf('2026-06-15 %02d:%02d:00', $seq % 24, $seq % 60),
        duration => 60, location_id => $loc->id, project_id => $prog->id,
        teacher_id => $teacher->id, capacity => $capacity, metadata => {} });
    $s->add_events($db, $e->id);
    return $s;
}
sub occupy ($session, $n) {
    Registry::DAO::Enrollment->create($db, {
        session_id => $session->id, family_member_id => a_child()->id,
        parent_id => $parent->id, status => 'active' }) for 1 .. $n;
}

# $priced controls whether each pair gets a payment_items row. A child with no
# line item is real: calculate_enrollment_total skips any child whose plan
# returns no price, so they ride along in enrollment_items with nothing behind
# them, and refund_share_for cannot resolve their share.
sub a_paid_cart (@pairs) {
    my $p = Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => 10000 * scalar @pairs,
        status => 'completed',
        metadata => {
            enrollment_items => [ map { { session_id => $_->{session}->id,
                                          child_id   => $_->{child}->id } } @pairs ],
            tenant_slug => undef } });
    $db->update('payments', { stripe_payment_intent_id => 'pi_ob_' . $p->id },
        { id => $p->id });
    for my $pair (@pairs) {
        next unless $pair->{priced} // 1;
        $db->insert('payment_items', {
            payment_id => $p->id, description => 'seat', amount_cents => 10000,
            metadata => { -json => { child_id   => $pair->{child}->id,
                                     session_id => $pair->{session}->id } } });
    }
    return Registry::DAO::Payment->find($db, { id => $p->id });
}

sub reload ($payment) { Registry::DAO::Payment->find($db, { id => $payment->id }) }

sub settle ($payment) {
    my $tx = $db->begin;
    $payment->finalize_enrollment($db);
    $tx->commit;
    return reload($payment);
}

sub status_for ($payment, $session) {
    my $row = $db->select('enrollments', ['status'],
        { payment_id => $payment->id, session_id => $session->id })->hash;
    return $row ? $row->{status} : undef;
}

subtest 'a second demotion adds to the debt rather than replacing it' => sub {
    # Pass 1 demotes A and the refund fails. Pass 2 demotes B. Assigning rather
    # than accumulating drops A's share on the floor, and because
    # demote_to_waitlisted only reports real transitions, no later pass can ever
    # re-derive it.
    # The real shape: an earlier delivery demoted someone and its refund failed,
    # so the row carries an unpaid balance. This delivery demotes a second
    # child. Assigning rather than accumulating drops the earlier balance, and
    # nothing can re-derive it -- that child is already waitlisted, so no later
    # pass sees a transition.
    my $session = a_session(1);
    my $earlier = a_child();
    my $now     = a_child();
    my $payment = a_paid_cart({ session => $session, child => $now });
    occupy($session, 1);

    # As a failed refund would have left it.
    my %meta = %{ $payment->metadata };
    $db->update('payments', {
        status   => 'refund_pending',
        metadata => { -json => { %meta,
            refund_owed_cents    => 10000,
            refund_owed_children => [ $earlier->id ] } },
    }, { id => $payment->id });

    my $after = settle( reload($payment) );
    is $after->metadata->{refund_owed_cents}, 20000,
        'the new demotion is added to the unpaid balance, not substituted for it';
    is scalar @{ $after->metadata->{refund_owed_children} }, 2,
        'and both children are named in the obligation';
};

subtest 'a pass that demotes nobody leaves an unpaid debt alone' => sub {
    # The manual-review flag persists in metadata, so any condition that tests it
    # re-enters the write path on a later delivery -- where nothing was newly
    # demoted and the computed debt is zero.
    my $session = a_session(1);
    my $payment = a_paid_cart(
        { session => $session, child => a_child() },
        { session => $session, child => a_child(), priced => 0 },
    );
    occupy($session, 1);

    my $after_one = settle($payment);
    is $after_one->metadata->{refund_owed_cents}, 10000, 'pass 1 owes the priced child';
    ok $after_one->metadata->{refund_manual_review}, 'and flags the unpriced one';

    my $after_two = settle(reload($payment));
    is $after_two->metadata->{refund_owed_cents}, 10000,
        'the unpaid debt survives a delivery that demotes nobody';
};

subtest 'an unresolvable share is still findable by the runbook' => sub {
    # If the only demoted child has no line item, the computed debt is zero --
    # but the family is still waitlisted and unrefunded. Leaving the row
    # 'completed' hides it from both the Task 9 runbook query and Leg 3's
    # ProcessRefunds, which scan for refund_pending.
    my $session = a_session(1);
    my $payment = a_paid_cart(
        { session => $session, child => a_child(), priced => 0 },
    );
    occupy($session, 1);

    my $after = settle($payment);
    ok $after->metadata->{refund_manual_review}, 'the share is flagged';
    is $after->status, 'refund_pending',
        'and the row is findable by a status scan, not silently completed';
};

subtest 'a redelivery does not re-adjudicate a seat already granted' => sub {
    # The spec requires the second settlement to short-circuit when this payment
    # already holds active rows. Without it, an enrollment that landed in the
    # meantime -- an admin add, a transfer, another cart -- demotes a child who
    # was seated and paid.
    my $session = a_session(2);
    my $child   = a_child();
    my $payment = a_paid_cart({ session => $session, child => $child });

    my $after_one = settle($payment);
    is status_for($payment, $session), 'active', 'the child is seated on pass 1';
    is $after_one->metadata->{refund_owed_cents}, undef, 'and owes nothing';

    # Fill the session past capacity from outside this payment. The predicate
    # excludes this payment's own rows, so on a second pass it sees the session
    # as full and would demote a child who is already seated and paid.
    occupy($session, 2);

    my $after_two = settle(reload($payment));
    is status_for($payment, $session), 'active',
        'a later delivery leaves the seated child alone';
    is $after_two->metadata->{refund_owed_cents}, undef,
        'and creates no obligation against a seat already granted';
};

subtest 'a pending seat short-circuits too' => sub {
    # payment_fits_session counts 'pending' against capacity, so a pending row
    # is a seat in hand. A short-circuit that only recognised 'active' would
    # re-adjudicate it and demote a child who holds a place.
    my $session = a_session(2);
    my $child   = a_child();
    my $payment = a_paid_cart({ session => $session, child => $child });

    Registry::DAO::Enrollment->create_for_payment($db, {
        session_id => $session->id, family_member_id => $child->id,
        parent_id => $parent->id, status => 'pending', payment_id => $payment->id });
    occupy($session, 2);    # the session is now full from outside

    my $after = settle( reload($payment) );
    is status_for($payment, $session), 'pending',
        'the pending seat is left alone rather than demoted';
    is $after->metadata->{refund_owed_cents}, undef, 'and owes nothing';
};

subtest 'the obligation key is stable across item ordering' => sub {
    # The key is derived from the owed-children list. If that list is not
    # ordered deterministically, a redelivery whose cart items arrive in a
    # different order mints a different key and Stripe refunds a second time.
    # Graded directly on the key rather than through two carts: the same
    # children in two payments collide on enrollments_session_student_type_unique,
    # which would make this die for a reason that has nothing to do with ordering.
    my $session = a_session(5);
    my $payment = a_paid_cart({ session => $session, child => a_child() });

    my %meta = %{ $payment->metadata };
    $db->update('payments',
        { metadata => { -json => { %meta, refund_owed_children => [ 'ccc', 'aaa', 'bbb' ] } } },
        { id => $payment->id });

    is reload($payment)->capacity_refund_key,
        'refund:capacity:' . $payment->id . ':aaa,bbb,ccc',
        'the key orders its child set, so a differently-ordered cart replays it';
};

done_testing;
