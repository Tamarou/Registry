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

sub status_for_child ($payment, $session, $child) {
    my $row = $db->select('enrollments', ['status'],
        { payment_id => $payment->id, session_id => $session->id,
          student_id => $child->id })->hash;
    return $row ? $row->{status} : undef;
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

subtest 'a cancelled enrollment is left alone, not resurrected and re-owed' => sub {
    # demote_to_waitlisted treats every non-waitlisted row as demotable, while
    # already_seated_by short-circuits only on active|pending. A cancelled row
    # falls between them: not short-circuited, so re-adjudicated; not
    # waitlisted, so counted as a fresh demotion. The admin drop is undone and
    # the share is owed a second time -- under a key Stripe has never seen, so
    # its 24-hour dedup does not apply. That is an un-deduplicated second
    # refund against a drop that was already refunded by another system.
    my $session = a_session(1);
    my $child   = a_child();
    my $payment = a_paid_cart({ session => $session, child => $child });

    settle($payment);
    is status_for($payment, $session), 'active', 'the child is seated on pass 1';

    # An admin drops the enrollment; the other refund system records its own
    # settlement on the enrollment row.
    $db->update('enrollments',
        { status => 'cancelled' },
        { payment_id => $payment->id, session_id => $session->id });
    occupy($session, 1);    # the freed seat is resold

    my $after = settle( reload($payment) );

    is status_for($payment, $session), 'cancelled',
        'the cancelled enrollment stays cancelled';
    is $after->metadata->{refund_owed_cents}, undef,
        'and no second obligation is created against a drop already settled';
};

subtest 'a seat held from an earlier pass counts against this cart capacity' => sub {
    # The short-circuit skips before $granted++, and payment_fits_session
    # excludes this payment's own rows -- so on a later delivery the cart is
    # invisible to itself and believes the session is empty.
    my $session = a_session(2);
    my @kids    = ( a_child(), a_child(), a_child() );
    my $payment = a_paid_cart( map { { session => $session, child => $_ } } @kids );

    my $first = settle($payment);
    my %seen;
    $seen{ $_->{status} }++ for @{ $db->select('enrollments', ['status'],
        { payment_id => $payment->id })->hashes };
    is $seen{active}, 2, 'pass 1 seats exactly the two available places';
    is $seen{waitlisted}, 1, 'and waitlists the third child';

    # Remove the waitlisted row, as an admin transfer or a manual cleanup would.
    # While it sits on (session, student, payment), create_for_payment's
    # DO NOTHING arbiter masks the miscount; without it the insert lands.
    $db->delete('enrollments',
        { payment_id => $payment->id, session_id => $session->id, status => 'waitlisted' });

    my $second = settle( reload($payment) );
    my $seated = $db->query(
        q{SELECT COUNT(*) FROM enrollments
           WHERE session_id = ? AND status IN ('active','pending')},
        $session->id)->array->[0];
    is $seated, 2, 'a later delivery does not oversell a 2-seat session';
};

subtest 'discharging an obligation clears the manual-review flag with it' => sub {
    # The flag is truthy forever once set, so every later delivery re-enters the
    # obligation write and stamps refund_pending over a terminal status.
    my $session = a_session(1);
    my $payment = a_paid_cart(
        { session => $session, child => a_child() },
        { session => $session, child => a_child(), priced => 0 },
    );
    occupy($session, 1);
    settle($payment);

    my $owing = reload($payment);
    ok $owing->metadata->{refund_manual_review}, 'the unresolvable share is flagged';

    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_refund_async =
            sub { Mojo::Promise->resolve({ id => 're_ob', status => 'succeeded' }) };
        # ->wait, not the imported settle(): this file defines its own settle()
        # for finalize_enrollment. Safe here -- prove runs no event loop.
        $owing->refund_async($db, { amount_cents => 10000,
                                    idempotency_key => $owing->capacity_refund_key })->wait;
    }

    my $done = reload($payment);
    ok !$done->metadata->{refund_manual_review},
        'discharging the obligation clears the flag too';
    isnt $done->status, 'refund_pending',
        'so a later delivery cannot stamp refund_pending over a terminal status';
};

subtest 'each layer of the cancelled protection is graded on its own' => sub {
    # The end-to-end subtest above is protected three ways -- the seat-state
    # category, the closed short-circuit, and the demotion vocabulary -- so any
    # one of them alone keeps it green. That is good defence and a bad test:
    # remove two layers later and nothing notices. These assert each layer.
    my $session = a_session(1);
    my $child   = a_child();
    my $payment = a_paid_cart({ session => $session, child => $child });
    settle($payment);

    is Registry::DAO::Enrollment->cart_seat_state(
        $db, $payment->id, $session->id, $child->id ), 'seated',
        'an active row reads as seated';

    $db->update('enrollments', { status => 'cancelled' },
        { payment_id => $payment->id, session_id => $session->id });
    is Registry::DAO::Enrollment->cart_seat_state(
        $db, $payment->id, $session->id, $child->id ), 'closed',
        'a cancelled row reads as closed, not as absent or waitlisted';

    # Layer 2: the demotion itself must refuse a row it does not own.
    my $moved = Registry::DAO::Enrollment->demote_to_waitlisted($db, {
        session_id => $session->id, family_member_id => $child->id,
        parent_id => $parent->id, payment_id => $payment->id });
    is $moved, 0, 'demoting a cancelled row reports no transition';
    is status_for($payment, $session), 'cancelled',
        'and leaves it cancelled rather than un-cancelling it';

    $db->update('enrollments', { status => 'waitlisted' },
        { payment_id => $payment->id, session_id => $session->id });
    is Registry::DAO::Enrollment->cart_seat_state(
        $db, $payment->id, $session->id, $child->id ), 'waitlisted',
        'a waitlisted row reads as waitlisted';
};

subtest 'a closed row does not consume a seat its sibling needs' => sub {
    # The closed short-circuit is not redundant with the other two layers. When
    # the session has room, a cancelled row that reaches the fits-check passes
    # it, calls create_for_payment -- a no-op against the existing row -- and
    # still increments $granted. That phantom seat is then counted against the
    # next sibling in the same cart, who is refused a place that exists.
    # Three children, two seats. One is dropped, freeing a place. The phantom
    # only bites a child who still needs the fits-check, so the cart needs a
    # third who was never seated.
    my $session = a_session(2);
    my $dropped = a_child();
    my $held    = a_child();
    my $waiting = a_child();
    my $payment = a_paid_cart( { session => $session, child => $dropped },
                               { session => $session, child => $held },
                               { session => $session, child => $waiting } );

    settle($payment);
    is status_for_child($payment, $session, $waiting), 'waitlisted',
        'the third child is waitlisted while the session is full';

    $db->update('enrollments', { status => 'cancelled' },
        { payment_id => $payment->id, session_id => $session->id,
          student_id => $dropped->id });
    $db->delete('enrollments',
        { payment_id => $payment->id, session_id => $session->id,
          student_id => $waiting->id });

    my $after = settle( reload($payment) );

    is status_for_child($payment, $session, $held), 'active',
        'the seated sibling keeps their place';
    is status_for_child($payment, $session, $waiting), 'active',
        'and the waiting child takes the freed seat rather than losing it to a phantom';
};

subtest 'a held seat counts regardless of where it sits in the cart' => sub {
    # The seat credit used to accrue as the loop reached each item, so an
    # unseated item earlier in the list was adjudicated against a capacity that
    # under-counted by every held seat still ahead of it -- and overfilled by
    # one. Order the cart so the unseated child comes first.
    my $session = a_session(2);
    my $unseated = a_child();
    my $holder   = a_child();

    # $holder already has one of the two seats, from an earlier delivery.
    my $payment = a_paid_cart( { session => $session, child => $unseated },
                               { session => $session, child => $holder } );
    Registry::DAO::Enrollment->create_for_payment($db, {
        session_id => $session->id, family_member_id => $holder->id,
        parent_id => $parent->id, status => 'active', payment_id => $payment->id });

    # And an outsider holds the other.
    occupy($session, 1);

    my $after = settle( reload($payment) );

    is status_for_child($payment, $session, $holder), 'active',
        'the held seat is untouched';
    is status_for_child($payment, $session, $unseated), 'waitlisted',
        'and the child listed before it is refused, not squeezed into a full session';

    my $filled = $db->query(
        q{SELECT COUNT(*) FROM enrollments
           WHERE session_id = ? AND status IN ('active','pending')},
        $session->id)->array->[0];
    is $filled, 2, 'the 2-seat session holds exactly two';
};

subtest 'a waitlisted child is not re-adjudicated when a seat frees up' => sub {
    # An earlier delivery demoted this child and owed their share back. A
    # redelivery after a seat frees cannot actually promote them --
    # create_for_payment conflicts on (session_id, student_id, payment_id)
    # against the row the demotion wrote and does nothing -- but without the
    # skip it still takes the seating branch, which credits %granted for a seat
    # that was never created and mails a confirmation to a family whose child
    # is on the waitlist with a refund outstanding.
    my $session = a_session(2);
    my $waiting = a_child();
    my $second  = a_child();
    my $payment = a_paid_cart( { session => $session, child => $waiting },
                               { session => $session, child => $second } );

    # Both seats taken by outsiders, so the first pass waitlists both children.
    occupy( $session, 2 );
    settle( reload($payment) );
    is status_for_child( $payment, $session, $waiting ), 'waitlisted',
        'the first pass waitlisted them';

    my $notes_before = $db->query(
        q{SELECT COUNT(*) FROM notifications WHERE user_id = ?},
        $parent->id)->array->[0];

    # An admin drops one outsider: exactly one seat is now genuinely free.
    $db->query(
        q{DELETE FROM enrollments WHERE id = (
              SELECT id FROM enrollments
               WHERE session_id = ? AND payment_id IS NULL
               LIMIT 1)}, $session->id);

    settle( reload($payment) );

    is status_for_child( $payment, $session, $waiting ), 'waitlisted',
        'the redelivery does not claim to seat a child it cannot seat';

    # This count is the only assertion here that catches the regression -- the
    # status assertion above passes either way. It depends on the fixture:
    # ensure_enrollment_confirmation dedupes on (user_id, type, session_id,
    # child_id), so had this child ever been seated in this session, the
    # spurious call would be swallowed and the count would stay flat with the
    # bug present. They are waitlisted on the first pass and never seated, so
    # the count genuinely rises. Fragile in the missed-detection direction
    # only; there is no false-failure path.
    is $db->query(q{SELECT COUNT(*) FROM notifications WHERE user_id = ?},
        $parent->id)->array->[0], $notes_before,
        'and sends no enrollment confirmation for a seat that was not created';
};

done_testing;
