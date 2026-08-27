#!/usr/bin/env perl
# ABOUTME: A child who dropped a session can enrol in it again, and pay for it.
# ABOUTME: The total constraint made that collision abort a captured settlement.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Enrollment;
use Registry::DAO::Payment;
use Registry::DAO::Notification;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_reenrol';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent = $dao->create(User => {
    username => 're_parent', name => 'RE Parent', user_type => 'parent',
    email => 're@test.local' });

my $n = 0;
sub a_child () {
    $n++;
    Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => "RE Kid $n", birth_date => '2015-01-01', grade => '4',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' } });
}

sub a_session () {
    $n++;
    my $loc = Registry::DAO::Location->create($db, {
        name => "RE Loc $n$$", slug => "re_loc_$n$$", address_info => {}, metadata => {} });
    my $proj = Registry::DAO::Project->create($db, {
        name => "RE Proj $n$$", status => 'published',
        program_type_slug => 'summer-camp', metadata => {} });
    my $teacher = $dao->create(User => {
        username => "re_t_$n$$", name => 'RE T', user_type => 'staff',
        email => "re_t_$n$$\@test.local" });
    my $event = Registry::DAO::Event->create($db, {
        location_id => $loc->id, project_id => $proj->id, teacher_id => $teacher->id,
        time => \'NOW()', duration => 60, capacity => 10, metadata => {} });
    my $s = Registry::DAO::Session->create($db, {
        name => "RE Session $n$$", status => 'published', capacity => 10, metadata => {} });
    $s->add_events($db, $event->id);
    return $s;
}

sub a_payment () {
    Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => 10000, status => 'pending',
        metadata => { enrollment_items => [], tenant_slug => undef } });
}

# The failure this migration exists to remove. Under the total constraint the
# second create_for_payment RAISED -- and it runs inside the settlement
# transaction, after Stripe has captured, with the die deliberately releasing
# the webhook dedup claim so every redelivery reproduced it. Money taken, no
# enrollment, no waitlist row, no refund owed, nothing to find.
subtest 'a child who dropped a session can be enrolled in it again' => sub {
    my $session = a_session();
    my $child   = a_child();
    my $first   = a_payment();
    my $second  = a_payment();

    Registry::DAO::Enrollment->create_for_payment($db, {
        session_id => $session->id, family_member_id => $child->id,
        parent_id => $parent->id, status => 'active', payment_id => $first->id });

    # Drops do not delete. The row survives, cancelled.
    $db->update('enrollments', { status => 'cancelled' },
        { session_id => $session->id, student_id => $child->id });

    my $err = do {
        local $@;
        eval { Registry::DAO::Enrollment->create_for_payment($db, {
            session_id => $session->id, family_member_id => $child->id,
            parent_id => $parent->id, status => 'active',
            payment_id => $second->id }); 1 };
        $@;
    };

    is $err, '', 'the re-enrolment does not raise inside a captured settlement';

    my $live = $db->query(
        q{SELECT COUNT(*) FROM enrollments
           WHERE session_id = ? AND student_id = ? AND status <> 'cancelled'},
        $session->id, $child->id)->array->[0];
    is $live, 1, 'and the child holds exactly one live seat';
};

# The rule that was actually wanted still holds.
subtest 'a child still cannot hold two live seats in one session' => sub {
    my $session = a_session();
    my $child   = a_child();

    Registry::DAO::Enrollment->create_for_payment($db, {
        session_id => $session->id, family_member_id => $child->id,
        parent_id => $parent->id, status => 'active', payment_id => a_payment()->id });

    my $err = do {
        local $@;
        eval { Registry::DAO::Enrollment->create_for_payment($db, {
            session_id => $session->id, family_member_id => $child->id,
            parent_id => $parent->id, status => 'active',
            payment_id => a_payment()->id }); 1 };
        $@;
    };

    like $err, qr/enrollments_session_student_type_live/,
        'a second LIVE seat for the same child is still refused';
};

subtest 'and two cancelled rows may coexist -- a child can drop twice' => sub {
    my $session = a_session();
    my $child   = a_child();

    for my $i ( 1 .. 2 ) {
        Registry::DAO::Enrollment->create_for_payment($db, {
            session_id => $session->id, family_member_id => $child->id,
            parent_id => $parent->id, status => 'active', payment_id => a_payment()->id });
        $db->update('enrollments', { status => 'cancelled' },
            { session_id => $session->id, student_id => $child->id, status => 'active' });
    }

    is $db->query(q{SELECT COUNT(*) FROM enrollments
                     WHERE session_id = ? AND student_id = ? AND status = 'cancelled'},
        $session->id, $child->id)->array->[0], 2,
        'two drops leave two cancelled rows, and neither blocks the other';
};

# M2 from the review: nothing distinguished `status <> 'cancelled'` from
# `status = 'active'`. Narrowing the index that way passed both files, and it is
# the narrowing that lets a waitlisted or pending row stop occupying its seat --
# so two live rows for one child could then coexist.
subtest 'every non-cancelled status occupies the seat, not just active' => sub {
    for my $held (qw( active pending waitlisted )) {
        my $session = a_session();
        my $child   = a_child();

        Registry::DAO::Enrollment->create_for_payment($db, {
            session_id => $session->id, family_member_id => $child->id,
            parent_id => $parent->id, status => $held, payment_id => a_payment()->id });

        my $err = do {
            local $@;
            eval { Registry::DAO::Enrollment->create_for_payment($db, {
                session_id => $session->id, family_member_id => $child->id,
                parent_id => $parent->id, status => 'active',
                payment_id => a_payment()->id }); 1 };
            $@;
        };
        like $err, qr/enrollments_session_student_type_live/,
            "a '$held' row still occupies the seat -- a second live row is refused";
    }
};

# And the cancelled row must actually survive the drop. If drops ever started
# deleting instead of cancelling, subtest 1 would pass for the wrong reason.
subtest 'the cancelled row is still there after the re-enrolment' => sub {
    my $session = a_session();
    my $child   = a_child();
    my $first   = a_payment();

    Registry::DAO::Enrollment->create_for_payment($db, {
        session_id => $session->id, family_member_id => $child->id,
        parent_id => $parent->id, status => 'active', payment_id => $first->id });
    $db->update('enrollments', { status => 'cancelled' },
        { session_id => $session->id, student_id => $child->id });

    Registry::DAO::Enrollment->create_for_payment($db, {
        session_id => $session->id, family_member_id => $child->id,
        parent_id => $parent->id, status => 'active', payment_id => a_payment()->id });

    is $db->query(q{SELECT COUNT(*) FROM enrollments
                     WHERE session_id = ? AND student_id = ? AND status = 'cancelled'},
        $session->id, $child->id)->array->[0], 1,
        'the dropped row is cancelled, not deleted -- the history survives';
};

# M3: nothing distinguished `IS DISTINCT FROM 'cancelled'` from `<> 'cancelled'`,
# which is the whole reason the deploy script argues for the former in a comment.
# NULL <> 'cancelled' is NULL, so under `<>` a NULL-status row falls outside the
# index entirely and any number of them can pile up on one seat.
#
# Both DAO write paths default the column (create_for_payment and create both
# `//=`), so this state is reachable only by raw SQL -- which is exactly what
# this subtest uses. The predicate is defence in depth, and depth that nothing
# grades is depth that silently rots back to `<>` the next time someone
# regenerates the schema.
subtest 'a NULL-status row still occupies the seat' => sub {
    my $session = a_session();
    my $child   = a_child();

    $db->query(
        'INSERT INTO enrollments (session_id, student_id, student_type, status)
         VALUES (?, ?, ?, NULL)', $session->id, $child->id, 'family_member' );

    my $err = do {
        local $@;
        eval { $db->query(
            'INSERT INTO enrollments (session_id, student_id, student_type, status)
             VALUES (?, ?, ?, NULL)', $session->id, $child->id, 'family_member' ); 1 };
        $@;
    };
    like $err, qr/enrollments_session_student_type_live/,
        'a second NULL-status row is refused -- NULL is not a free seat';
};

# The named arbiter's OTHER job. create_for_payment's comment says the arbiter
# makes calling it twice for the same payment safe, and nothing graded that:
# replacing the arbiter so a same-payment replay RAISES left every test in the
# money path green. The reason is a conjunction trap -- finalize_enrollment's
# `next if $held eq 'seated'` short-circuits before the second insert on every
# replay path a test drives, so the arbiter is never actually asked. It is asked
# when two deliveries race and both read 'none'.
#
# So ask it directly, with no settlement loop in the way.
subtest 'create_for_payment absorbs its own replay' => sub {
    my $session = a_session();
    my $child   = a_child();
    my $payment = a_payment();

    my %row = ( session_id => $session->id, family_member_id => $child->id,
                parent_id => $parent->id, status => 'active',
                payment_id => $payment->id );

    Registry::DAO::Enrollment->create_for_payment($db, {%row});
    my $err = do {
        local $@;
        eval { Registry::DAO::Enrollment->create_for_payment($db, {%row}); 1 };
        $@;
    };
    is $err, '', 'the identical second insert is absorbed, not raised';

    is $db->query(q{SELECT COUNT(*) FROM enrollments
                     WHERE session_id = ? AND student_id = ? AND payment_id = ?},
        $session->id, $child->id, $payment->id)->array->[0], 1,
        'and it left exactly one row';
};

# Re-enrolling is what this migration exists to allow, and the confirmation
# email is the only email the paid path sends. The dedup key was
# (user, type, session, child) with no time bound and nothing deleting the
# notification on a drop -- which could never misfire while the total constraint
# made a second enrolment for that pair impossible. It is now the happy path, so
# the stale row from the enrolment the family already dropped silences the
# confirmation for the one they just paid for.
subtest 'a re-enrolment is confirmed, not silenced by the dropped one' => sub {
    my $session = a_session();
    my $child   = a_child();

    my $count = sub {
        $db->query( q{SELECT COUNT(*) FROM notifications
                       WHERE user_id = ? AND type = 'enrollment_confirmation'
                         AND metadata->>'session_id' = ?},
            $parent->id, $session->id )->array->[0];
    };

    my %row = ( session_id => $session->id, family_member_id => $child->id,
                parent_id => $parent->id, status => 'active' );
    my $confirm = sub ($enrollment_id) {
        Registry::DAO::Notification->ensure_enrollment_confirmation($db, {
            user_id       => $parent->id, session_id => $session->id,
            child_id      => $child->id, enrollment_id => $enrollment_id });
    };

    my $first = Registry::DAO::Enrollment->create_for_payment(
        $db, { %row, payment_id => a_payment()->id } );
    $confirm->($first);
    is $count->(), 1, 'the first enrolment is confirmed';

    # The same delivery arriving twice must NOT produce a second email. The
    # arbiter absorbs the insert and hands back the SAME enrolment id, which is
    # what makes the dedup hold.
    my $replay = Registry::DAO::Enrollment->create_for_payment(
        $db, { %row, payment_id => $db->query(
            'SELECT payment_id FROM enrollments WHERE id = ?', $first)->array->[0] } );
    is $replay, $first, 'a replay resolves to the same enrolment';
    $confirm->($replay);
    is $count->(), 1, 'a redelivery of that enrolment is still one email';

    $db->update('enrollments', { status => 'cancelled' },
        { session_id => $session->id, student_id => $child->id });

    my $second = Registry::DAO::Enrollment->create_for_payment(
        $db, { %row, payment_id => a_payment()->id } );
    isnt $second, $first, 're-enrolling creates a new enrolment, not a revival';
    $confirm->($second);
    is $count->(), 2, 'the re-enrolment the family paid for is confirmed too';
};

done_testing;
