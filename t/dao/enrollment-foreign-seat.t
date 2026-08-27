#!/usr/bin/env perl
# ABOUTME: A seat held by a DIFFERENT payment is visible to the cart adjudicating against it.
# ABOUTME: Scoping the seat lookup by payment_id made a foreign row read as no row at all.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Enrollment;
use Registry::DAO::Payment;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_foreign_seat';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent = $dao->create(User => {
    username => 'fs_parent', name => 'FS Parent', user_type => 'parent',
    email => 'fs@test.local' });

my $n = 0;
sub a_child () {
    $n++;
    Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => "FS Kid $n", birth_date => '2015-01-01', grade => '4',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' } });
}
sub a_session ($capacity = 10) {
    $n++;
    my $loc = Registry::DAO::Location->create($db, {
        name => "FS Loc $n$$", slug => "fs_loc_$n$$", address_info => {}, metadata => {} });
    my $proj = Registry::DAO::Project->create($db, {
        name => "FS Proj $n$$", status => 'published',
        program_type_slug => 'summer-camp', metadata => {} });
    my $teacher = $dao->create(User => {
        username => "fs_t_$n$$", name => 'FS T', user_type => 'staff',
        email => "fs_t_$n$$\@test.local" });
    my $event = Registry::DAO::Event->create($db, {
        location_id => $loc->id, project_id => $proj->id, teacher_id => $teacher->id,
        time => \'NOW()', duration => 60, capacity => $capacity, metadata => {} });
    my $s = Registry::DAO::Session->create($db, {
        name => "FS Session $n$$", status => 'published',
        capacity => $capacity, metadata => {} });
    $s->add_events($db, $event->id);
    return $s;
}
# A cart with a sibling in it. The single-child helper cannot expose a
# re-owed debt: with one child the first debt equals the whole cart, and
# record_capacity_obligation's clamp absorbs every later one. Headroom is what
# makes a second increment representable, so a sibling is load-bearing here.
sub a_paid_cart_for (@children) {
    my ($session, @kids) = @children;
    my $each = 5000;
    my $p = Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => $each * @kids, status => 'completed',
        metadata => {
            enrollment_items => [ map { { session_id => $session->id, child_id => $_->id } } @kids ],
            tenant_slug      => undef } });
    $db->insert('payment_items', {
        payment_id => $p->id, description => 'seat', amount_cents => $each,
        metadata => { -json => { child_id => $_->id, session_id => $session->id } } })
        for @kids;
    return Registry::DAO::Payment->find($db, { id => $p->id });
}

# A cart whose line item is missing or nonsensical. calculate_enrollment_total
# skips any child whose plan returns no price, so a child can ride in
# enrollment_items with nothing behind them.
sub a_cart_without_line_item ($session, $child, $cents = 5000) {
    my $p = Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => $cents, status => 'completed',
        metadata => {
            enrollment_items => [ { session_id => $session->id, child_id => $child->id } ],
            tenant_slug      => undef } });
    return Registry::DAO::Payment->find($db, { id => $p->id });
}

sub a_paid_cart ($session, $child, $cents = 10000) {
    my $p = Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => $cents, status => 'completed',
        metadata => {
            enrollment_items => [ { session_id => $session->id, child_id => $child->id } ],
            tenant_slug      => undef } });
    $db->insert('payment_items', {
        payment_id => $p->id, description => 'seat', amount_cents => $cents,
        metadata => { -json => { child_id => $child->id, session_id => $session->id } } });
    return Registry::DAO::Payment->find($db, { id => $p->id });
}

# The gap, stated directly. cart_seat_state scoped its lookup by payment_id, so
# a live seat held by ANOTHER payment read as 'none' -- the caller then
# adjudicated as if the child were unseated and tried to insert, colliding with
# enrollments_session_student_type_live inside a settlement Stripe had already
# captured.
subtest 'a seat held by another payment is visible, and distinct from our own' => sub {
    my $session = a_session();
    my $child   = a_child();
    my $theirs  = a_paid_cart( $session, $child );
    my $ours    = a_paid_cart( $session, $child );

    Registry::DAO::Enrollment->create_for_payment($db, {
        session_id => $session->id, family_member_id => $child->id,
        parent_id => $parent->id, status => 'active', payment_id => $theirs->id });

    is Registry::DAO::Enrollment->cart_seat_state(
        $db, $theirs->id, $session->id, $child->id ), 'seated',
        'the payment that holds it sees its own seat';

    is Registry::DAO::Enrollment->cart_seat_state(
        $db, $ours->id, $session->id, $child->id ), 'foreign',
        'and another cart sees it as foreign -- not as no seat at all';
};

# 'foreign' has to be its own category rather than 'seated'.
# payment_fits_session already counts foreign rows in $taken, so crediting one
# to %granted would count the same seat twice and under-count the capacity left
# for the next sibling in the cart.
subtest 'a foreign seat is not credited to this cart' => sub {
    my $session = a_session(2);
    my $kid_a   = a_child();
    my $kid_b   = a_child();
    my $theirs  = a_paid_cart( $session, $kid_a );

    Registry::DAO::Enrollment->create_for_payment($db, {
        session_id => $session->id, family_member_id => $kid_a->id,
        parent_id => $parent->id, status => 'active', payment_id => $theirs->id });

    # Our cart names both children; kid_a is already seated by $theirs.
    my $ours = Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => 20000, status => 'completed',
        metadata => { tenant_slug => undef, enrollment_items => [
            { session_id => $session->id, child_id => $kid_a->id },
            { session_id => $session->id, child_id => $kid_b->id } ] } });
    for my $kid ( $kid_a, $kid_b ) {
        $db->insert('payment_items', {
            payment_id => $ours->id, description => 'seat', amount_cents => 10000,
            metadata => { -json => { child_id => $kid->id, session_id => $session->id } } });
    }

    my $err = do {
        local $@;
        eval { Registry::DAO::Payment->find($db, { id => $ours->id })
                   ->finalize_enrollment($db); 1 };
        $@;
    };
    is $err, '', 'the settlement does not raise on the collision';

    my $seated_b = $db->query(
        q{SELECT COUNT(*) FROM enrollments
           WHERE session_id = ? AND student_id = ? AND payment_id = ?
             AND status IN ('active','pending')},
        $session->id, $kid_b->id, $ours->id)->array->[0];
    is $seated_b, 1,
        'the sibling who needed a seat gets one -- the foreign seat did not '
        . 'consume the capacity twice';

    my $live_a = $db->query(
        q{SELECT COUNT(*) FROM enrollments
           WHERE session_id = ? AND student_id = ? AND status <> 'cancelled'},
        $session->id, $kid_a->id)->array->[0];
    is $live_a, 1, 'and the already-seated child still holds exactly one seat';
};

# The parent paid for a seat their child already had. That money is owed back.
subtest 'a cart that paid for a seat the child already holds is owed a refund' => sub {
    my $session = a_session();
    my $child   = a_child();
    my $theirs  = a_paid_cart( $session, $child );
    my $ours    = a_paid_cart( $session, $child, 7500 );

    Registry::DAO::Enrollment->create_for_payment($db, {
        session_id => $session->id, family_member_id => $child->id,
        parent_id => $parent->id, status => 'active', payment_id => $theirs->id });

    Registry::DAO::Payment->find($db, { id => $ours->id })->finalize_enrollment($db);

    my $row = $db->select('payments', '*', { id => $ours->id })->expand->hash;
    is $row->{refund_owed_cents}, 7500,
        'the duplicate payment owes its share back rather than keeping it';
    is $row->{status}, 'refund_pending', 'and the row says so';
};

# The three cases #315 names that a schema predicate alone does not cover. Each
# is a row cart_seat_state must report as 'foreign' even though the seat-holding
# vocabulary says it holds no seat: the uniqueness rule collides with it either
# way, inside a settlement Stripe has already captured.
subtest 'a waitlisted row belonging to another payment is seen, not stepped on' => sub {
    my $session = a_session();
    my $child   = a_child();
    my $theirs  = a_paid_cart( $session, $child );
    my $ours    = a_paid_cart( $session, $child, 6200 );

    Registry::DAO::Enrollment->create_for_payment($db, {
        session_id => $session->id, family_member_id => $child->id,
        parent_id => $parent->id, status => 'waitlisted', payment_id => $theirs->id });

    is Registry::DAO::Enrollment->cart_seat_state(
        $db, $ours->id, $session->id, $child->id ), 'foreign',
        'a foreign waitlisted row is foreign, not none';

    my $err = do {
        local $@;
        eval { Registry::DAO::Payment->find($db, { id => $ours->id })
                   ->finalize_enrollment($db); 1 };
        $@;
    };
    is $err, '', 'and the settlement does not raise on it';
};

# An admin-created enrollment carries no payment_id at all.
subtest 'an admin-created enrollment is seen by the cart that pays afterwards' => sub {
    my $session = a_session();
    my $child   = a_child();
    my $ours    = a_paid_cart( $session, $child, 4400 );

    Registry::DAO::Enrollment->create($db, {
        session_id => $session->id, student_id => $child->id,
        family_member_id => $child->id, parent_id => $parent->id,
        status => 'pending' });

    is Registry::DAO::Enrollment->cart_seat_state(
        $db, $ours->id, $session->id, $child->id ), 'foreign',
        'a row with no payment_id is foreign to this cart';

    my $err = do {
        local $@;
        eval { Registry::DAO::Payment->find($db, { id => $ours->id })
                   ->finalize_enrollment($db); 1 };
        $@;
    };
    is $err, '', 'and the settlement does not raise on it';
};

# A cancelled foreign row must NOT read as foreign -- it holds no seat, and the
# relaxed index lets the insert through. Reporting it as foreign would refuse a
# seat the parent legitimately paid for.
subtest 'a cancelled foreign row leaves the seat available' => sub {
    my $session = a_session();
    my $child   = a_child();
    my $theirs  = a_paid_cart( $session, $child );
    my $ours    = a_paid_cart( $session, $child );

    Registry::DAO::Enrollment->create_for_payment($db, {
        session_id => $session->id, family_member_id => $child->id,
        parent_id => $parent->id, status => 'active', payment_id => $theirs->id });
    $db->update('enrollments', { status => 'cancelled' },
        { session_id => $session->id, student_id => $child->id });

    is Registry::DAO::Enrollment->cart_seat_state(
        $db, $ours->id, $session->id, $child->id ), 'none',
        'a dead row is not a foreign seat';

    Registry::DAO::Payment->find($db, { id => $ours->id })->finalize_enrollment($db);

    is $db->query(q{SELECT COUNT(*) FROM enrollments
                     WHERE session_id = ? AND student_id = ? AND payment_id = ?
                       AND status <> 'cancelled'},
        $session->id, $child->id, $ours->id)->array->[0], 1,
        'and the paying cart gets its seat';
};

# The duplicate-seat branch owes money. Every OTHER branch in that loop is
# idempotent because it WROTE something a later pass reads back: demotion leaves
# a waitlisted row, a drop leaves a cancelled one. This branch used to write
# nothing, so cart_seat_state answered 'foreign' forever and every redelivery
# owed the same child again -- under a fresh refund_seq, which means a fresh
# Stripe idempotency key, which means Stripe does NOT deduplicate it.
#
# A page refresh is enough. _apply_intent reports already_completed for any
# settled status, and refund_pending is one; finalize_enrollment's own gate is
# _money_returned, which deliberately is not.
subtest 'a duplicate seat is owed once, however many deliveries arrive' => sub {
    my $session = a_session();
    my $dup     = a_child();   # already seated by someone else
    my $sibling = a_child();   # seats normally, and leaves the headroom
    my $theirs  = a_paid_cart( $session, $dup );
    my $ours    = a_paid_cart_for( $session, $dup, $sibling );

    Registry::DAO::Enrollment->create_for_payment($db, {
        session_id => $session->id, family_member_id => $dup->id,
        parent_id => $parent->id, status => 'active', payment_id => $theirs->id });

    Registry::DAO::Payment->find($db, { id => $ours->id })->finalize_enrollment($db);
    my $first = $db->query('SELECT refund_owed_cents FROM payments WHERE id = ?',
        $ours->id)->array->[0];
    is $first, 5000, 'the first delivery owes the duplicate share back';

    # The redelivery, driven exactly as the settlement callers drive it.
    Registry::DAO::Payment->find($db, { id => $ours->id })->finalize_enrollment($db);
    Registry::DAO::Payment->find($db, { id => $ours->id })->finalize_enrollment($db);

    my $row = $db->query(q{SELECT refund_owed_cents, refund_seq,
                                  jsonb_array_length(refund_increments) AS n
                             FROM payments WHERE id = ?}, $ours->id)->hash;
    is $row->{refund_owed_cents}, 5000,
        'three deliveries owe one debt, not three';
    is $row->{n}, 1,
        'and record exactly one increment -- a second would carry a new Stripe key';
};

# A NULL status is legal: the column is nullable and enrollments_status_check
# is `status = ANY(...)`, which is NULL rather than false for NULL, so the CHECK
# passes. Such a row sits INSIDE the live index (NULL IS DISTINCT FROM
# 'cancelled' is true), so the insert really would collide. Under a `<>`
# predicate this classifier would report 'none' and the caller would find out by
# raising inside a captured settlement -- the exact failure this file exists to
# prevent. The index is graded for this one file over; the DAO mirror was not.
subtest 'a NULL-status foreign row is a collision, not an empty seat' => sub {
    my $session = a_session();
    my $child   = a_child();
    my $ours    = a_paid_cart( $session, $child, 5000 );

    $db->query(
        'INSERT INTO enrollments (session_id, student_id, student_type, status)
         VALUES (?, ?, ?, NULL)', $session->id, $child->id, 'family_member' );

    is Registry::DAO::Enrollment->cart_seat_state(
        $db, $ours->id, $session->id, $child->id ), 'foreign',
        'a NULL-status row is seen';

    my $err = do {
        local $@;
        eval { Registry::DAO::Payment->find($db, { id => $ours->id })
                   ->finalize_enrollment($db); 1 };
        $@;
    };
    is $err, '', 'and the settlement does not raise on it';
};

# The index keys on student_type. A row of a different type is not a collision,
# so reporting it as one refunds a seat the insert would have granted.
subtest 'a foreign row of a different student_type is not a collision' => sub {
    my $session = a_session();
    my $child   = a_child();
    my $ours    = a_paid_cart( $session, $child, 5000 );

    $db->query(
        q{INSERT INTO enrollments (session_id, student_id, student_type, status)
          VALUES (?, ?, 'individual', 'active')}, $session->id, $child->id );

    is Registry::DAO::Enrollment->cart_seat_state(
        $db, $ours->id, $session->id, $child->id ), 'none',
        'a different student_type leaves the seat free';

    Registry::DAO::Payment->find($db, { id => $ours->id })->finalize_enrollment($db);
    is $db->query(q{SELECT COUNT(*) FROM enrollments
                     WHERE session_id = ? AND student_id = ? AND payment_id = ?},
        $session->id, $child->id, $ours->id)->array->[0], 1,
        'and the cart gets the seat the index would have granted it';
};

# The duplicate-seat branch flags for review when the share cannot be resolved.
# Deleting that flag changed nothing observable: the identical catch on the
# demotion path is graded by three subtests, this one by none.
subtest 'an unresolvable duplicate share is flagged, not settled clean' => sub {
    my $session = a_session();
    my $child   = a_child();
    my $theirs  = a_paid_cart( $session, $child );
    my $ours    = a_cart_without_line_item( $session, $child );

    Registry::DAO::Enrollment->create_for_payment($db, {
        session_id => $session->id, family_member_id => $child->id,
        parent_id => $parent->id, status => 'active', payment_id => $theirs->id });

    Registry::DAO::Payment->find($db, { id => $ours->id })->finalize_enrollment($db);

    my $row = $db->query(q{SELECT status, metadata->'refund_manual_review' AS flag
                             FROM payments WHERE id = ?}, $ours->id)->hash;
    ok $row->{flag}, 'the unresolvable share is flagged for a human';
    isnt $row->{status}, 'completed',
        'and the cart does not settle looking clean';
};

# A negative share must not net off a sibling's real debt. The obligation writer
# guards the cart TOTAL, so a cart of +5000 and -2000 recorded 3000, tripped no
# guard, wrote no flag and warned nobody -- leaving the child who really lost
# their seat under-refunded by 2000 with nothing to find. One child alone does
# not grade this: the total is then negative and the aggregate guard does fire.
# The masking needs a sibling, which is the whole point.
subtest 'a negative share does not silently net off a sibling real debt' => sub {
    my $session  = a_session();
    my $honest   = a_child();
    my $nonsense = a_child();

    my $p = Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => 5000, status => 'completed',
        metadata => { tenant_slug => undef, enrollment_items => [
            { session_id => $session->id, child_id => $honest->id },
            { session_id => $session->id, child_id => $nonsense->id } ] } });
    $db->insert('payment_items', {
        payment_id => $p->id, description => 'seat', amount_cents => 5000,
        metadata => { -json => { child_id => $honest->id, session_id => $session->id } } });
    $db->insert('payment_items', {
        payment_id => $p->id, description => 'discounted past zero',
        amount_cents => -2000,
        metadata => { -json => { child_id => $nonsense->id, session_id => $session->id } } });

    # Both children already hold seats from elsewhere, so both take the
    # duplicate-seat branch and both shares are accumulated.
    for my $kid ( $honest, $nonsense ) {
        my $theirs = a_paid_cart( $session, $kid );
        Registry::DAO::Enrollment->create_for_payment($db, {
            session_id => $session->id, family_member_id => $kid->id,
            parent_id => $parent->id, status => 'active', payment_id => $theirs->id });
    }

    Registry::DAO::Payment->find($db, { id => $p->id })->finalize_enrollment($db);

    my $row = $db->query(q{SELECT refund_owed_cents,
                                  metadata->'refund_manual_review' AS flag
                             FROM payments WHERE id = ?}, $p->id)->hash;
    is $row->{refund_owed_cents}, 5000,
        'the honest share is owed in full, not reduced by the nonsense one';
    ok $row->{flag}, 'and the nonsense share is put in front of a human';
};

# The operator runbook tells whoever is clearing a stranded refund_pending row
# to look at the enrollment state to work out WHICH failure they are holding:
# a demoted child leaves a waitlisted row, a duplicate seat leaves a cancelled
# one. That is a documented diagnostic, so it is a promise the code has to keep
# -- and it is invisible to every other test here, which look at payments.
subtest 'the two routes to refund_pending leave distinguishable enrollment state' => sub {
    # Route 1: the seat was gone, so the child was demoted.
    my $full   = a_session(1);
    my $hog    = a_child();
    my $late   = a_child();
    my $held   = a_paid_cart( $full, $hog );
    Registry::DAO::Enrollment->create_for_payment($db, {
        session_id => $full->id, family_member_id => $hog->id,
        parent_id => $parent->id, status => 'active', payment_id => $held->id });
    my $gone = a_paid_cart( $full, $late, 5000 );
    Registry::DAO::Payment->find($db, { id => $gone->id })->finalize_enrollment($db);

    # Route 2: the seat was already theirs, from a different payment.
    my $session = a_session();
    my $child   = a_child();
    my $theirs  = a_paid_cart( $session, $child );
    Registry::DAO::Enrollment->create_for_payment($db, {
        session_id => $session->id, family_member_id => $child->id,
        parent_id => $parent->id, status => 'active', payment_id => $theirs->id });
    my $dup = a_paid_cart( $session, $child, 5000 );
    Registry::DAO::Payment->find($db, { id => $dup->id })->finalize_enrollment($db);

    for my $case ( [ 'a demoted child', $gone, 'waitlisted' ],
                   [ 'a duplicate seat', $dup, 'cancelled' ] ) {
        my ( $name, $payment, $want ) = @$case;
        is_deeply $db->query(
            'SELECT status FROM enrollments WHERE payment_id = ?', $payment->id
        )->arrays->flatten->to_array, [$want],
            "$name leaves exactly one '$want' row for its payment";
        is $db->query( 'SELECT status FROM payments WHERE id = ?', $payment->id
        )->array->[0], 'refund_pending', "$name reaches refund_pending";
    }
};

done_testing;
