#!/usr/bin/env perl
# ABOUTME: A live waitlist offer reserves the seat it was made for, and acceptance re-checks capacity.
# ABOUTME: Neither was true: the 48-hour window reserved nothing and accept_offer never counted seats.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Test::Registry::DB;
use Registry::DAO::Enrollment;
use Registry::DAO::Payment;
use Registry::DAO::Waitlist;
use Registry::DAO::Family;
use Registry::DAO::Session;
use Registry::DAO::User;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_offer_holds_a_seat';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $loc = $dao->create(Location => {
    name => 'Hold Studio', slug => 'hold-studio', address_info => {}, metadata => {} });
my $prog = $dao->create(Project => {
    status => 'published', name => 'Hold Camp',
    program_type_slug => 'summer-camp', metadata => {} });
my $teacher = $dao->create(User => {
    username => 'hold_teacher', name => 'T', user_type => 'staff',
    email => 'holdt@test.local' });
my $parent = $dao->create(User => {
    username => 'hold_parent', name => 'Hold Parent', user_type => 'parent',
    email => 'hold@test.local' });

my $seq = 0;
sub a_child () {
    $seq++;
    Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => "Hold Kid $seq", birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' } });
}

sub a_session ($capacity) {
    $seq++;
    my $s = $dao->create(Session => {
        name => "Hold Week $seq", start_date => '2026-01-01', end_date => '2026-12-31',
        status => 'published', capacity => $capacity, metadata => {} });
    my $e = $dao->create(Event => {
        time => sprintf('2026-08-15 %02d:%02d:00', $seq % 24, $seq % 60),
        duration => 60, location_id => $loc->id, project_id => $prog->id,
        teacher_id => $teacher->id, capacity => $capacity, metadata => {} });
    $s->add_events($db, $e->id);
    return $s;
}

sub a_cart ( $session, @children ) {
    my $p = Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => 10000 * scalar @children,
        status => 'completed',
        metadata => {
            enrollment_items => [ map { { session_id => $session->id, child_id => $_->id } }
                                  @children ],
            tenant_slug => undef } });
    return Registry::DAO::Payment->find($db, { id => $p->id });
}

sub an_offer ( $session, $child, %opts ) {
    my $entry = Registry::DAO::Waitlist->create($db, {
        session_id => $session->id, location_id => $loc->id,
        student_id => $child->id, parent_id => $parent->id,
        status => 'waiting' });
    $db->query(
        q{UPDATE waitlist SET status = ?, offered_at = NOW(),
                 expires_at = NOW() + ? * INTERVAL '1 hour'
           WHERE id = ?},
        $opts{status} // 'offered', $opts{hours} // 48, $entry->id );
    return Registry::DAO::Waitlist->find($db, { id => $entry->id });
}

subtest 'a live offer holds the seat against another cart' => sub {
    my $session = a_session(1);
    an_offer( $session, a_child() );

    # A different family arriving at checkout for the last seat. The offer is a
    # promise of that seat for 48 hours; nothing counted it, so this cart was
    # told there was room and the accepting family lost the seat they were
    # offered.
    my $other = a_cart( $session, a_child() );
    ok !Registry::DAO::Enrollment->payment_fits_session( $db, $other, $session->id ),
        'the seat under offer is not available to somebody else';
};

subtest 'an expired or declined offer holds nothing' => sub {
    my $expired = a_session(1);
    an_offer( $expired, a_child(), hours => -1 );
    ok Registry::DAO::Enrollment->payment_fits_session(
        $db, a_cart( $expired, a_child() ), $expired->id ),
        'an offer past its expiry is not a hold';

    my $declined = a_session(1);
    an_offer( $declined, a_child(), status => 'declined' );
    ok Registry::DAO::Enrollment->payment_fits_session(
        $db, a_cart( $declined, a_child() ), $declined->id ),
        'nor is one that was declined';

    my $waiting = a_session(1);
    an_offer( $waiting, a_child(), status => 'waiting' );
    ok Registry::DAO::Enrollment->payment_fits_session(
        $db, a_cart( $waiting, a_child() ), $waiting->id ),
        'and queueing is not holding -- only an offer reserves';
};

subtest "a family's own offer does not block their own seat" => sub {
    # The whole point of holding it. The cart paying for the offered seat must
    # not be refused by the hold that exists for it.
    my $session = a_session(1);
    my $child   = a_child();
    an_offer( $session, $child );

    ok Registry::DAO::Enrollment->payment_fits_session(
        $db, a_cart( $session, $child ), $session->id ),
        'the cart that holds the offer can take the seat';
};

subtest 'accepting an offer into a session that filled is refused' => sub {
    my $session = a_session(1);
    my $child   = a_child();
    my $offer   = an_offer( $session, $child );

    # The seat went to somebody else while the offer sat in an inbox. Nothing
    # re-checked, so acceptance enrolled them past the limit and the oversell
    # only showed up on a roster.
    Registry::DAO::Enrollment->create($db, {
        session_id => $session->id, family_member_id => a_child()->id,
        parent_id => $parent->id, status => 'active' });

    my $ok = eval { $offer->accept_offer($db); 1 };
    ok !$ok, 'acceptance is refused';
    like $@, qr/full|capacity|no room/i, 'and says why';

    my $seated = $db->query(
        q{SELECT COUNT(*) FROM enrollments
           WHERE session_id = ? AND status IN ('active','pending')},
        $session->id )->array->[0];
    is $seated, 1, 'the session is not oversold';
};

done_testing;
