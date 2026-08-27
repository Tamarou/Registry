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

done_testing;
