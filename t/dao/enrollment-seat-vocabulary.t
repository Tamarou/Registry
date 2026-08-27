#!/usr/bin/env perl
# ABOUTME: One rule decides which enrollment statuses hold a seat, for all three consumers.
# ABOUTME: cart_seat_state, payment_fits_session and demote_to_waitlisted must never diverge.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Enrollment;
use Registry::DAO::Payment;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_seat_vocabulary';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent = $dao->create(User => {
    username => 'sv_parent', name => 'SV Parent', user_type => 'parent',
    email => 'sv@test.local' });

my $n = 0;
sub a_child () {
    $n++;
    Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => "SV Kid $n", birth_date => '2015-01-01', grade => '4',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' } });
}

sub a_session ($capacity) {
    my $loc = Registry::DAO::Location->create($db, {
        name => "SV Loc $n$$", slug => "sv_loc_$n$$", address_info => {}, metadata => {} });
    my $proj = Registry::DAO::Project->create($db, {
        name => "SV Proj $n$$", status => 'published',
        program_type_slug => 'summer-camp', metadata => {} });
    my $teacher = $dao->create(User => {
        username => "sv_t_$n$$", name => 'SV T', user_type => 'staff',
        email => "sv_t_$n$$\@test.local" });
    my $event = Registry::DAO::Event->create($db, {
        location_id => $loc->id, project_id => $proj->id, teacher_id => $teacher->id,
        time => \'NOW()', duration => 60, capacity => $capacity, metadata => {} });
    my $s = Registry::DAO::Session->create($db, {
        name => "SV Session $n$$", status => 'published', capacity => $capacity, metadata => {} });
    $s->add_events($db, $event->id);
    return $s;
}

sub a_payment () {
    Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => 10000, status => 'pending',
        metadata => { enrollment_items => [], tenant_slug => undef } });
}

# The whole point of section 2.4: one owner, and the consumers read from it rather
# than each carrying a copy of the list.
subtest 'the seat-holding vocabulary has exactly one owner' => sub {
    my $held = Registry::DAO::Enrollment->seat_holding_statuses;
    is ref $held, 'ARRAY', 'it is a list';
    is_deeply [ sort @$held ], [qw( active pending )],
        'active and pending hold a seat; nothing else does';
};

# The property that matters. For every status the column can carry, the three
# consumers must agree on whether it occupies a seat:
#   - cart_seat_state must call it 'seated'
#   - payment_fits_session must count it against capacity
#   - demote_to_waitlisted must be willing to demote it
# A divergence in any one is a money defect: the capacity arithmetic
# over- or under-counts, or an admin's cancellation gets un-done.
subtest 'all three consumers agree, status by status' => sub {
    my %expect_seated = ( active => 1, pending => 1,
                          waitlisted => 0, cancelled => 0 );

    # Cover the whole vocabulary, and notice if it grows. enrollments_status_check
    # is the authority; a status added there without a decision here would
    # silently default to "does not hold a seat" in cart_seat_state's `closed`
    # fallback, which is the safe direction only by luck.
    my $allowed = $db->query(q{
        SELECT pg_get_constraintdef(oid) FROM pg_constraint
         WHERE conname = 'enrollments_status_check'
    })->array->[0];
    my @in_db = sort( $allowed =~ /'([a-z_]+)'::text/g );
    is_deeply [ sort keys %expect_seated ], [ @in_db ],
        'this test covers every status the column permits';

    for my $status ( sort keys %expect_seated ) {
        my $seated  = $expect_seated{$status};
        my $session = a_session(1);
        my $child   = a_child();
        my $payment = a_payment();

        Registry::DAO::Enrollment->create_for_payment($db, {
            session_id => $session->id, family_member_id => $child->id,
            parent_id => $parent->id, status => $status, payment_id => $payment->id });

        # Consumer 1: the cart's own view of this child.
        my $state = Registry::DAO::Enrollment->cart_seat_state(
            $db, $payment->id, $session->id, $child->id );
        is $state eq 'seated' ? 1 : 0, $seated,
            "cart_seat_state: '$status' " . ( $seated ? 'holds' : 'does not hold' ) . ' a seat';

        # Consumer 2: capacity, seen by a DIFFERENT payment, so this row counts
        # as somebody else's occupancy rather than being self-excluded.
        my $other = a_payment();
        my $fits  = Registry::DAO::Enrollment->payment_fits_session(
            $db, $other, $session->id );
        is $fits ? 0 : 1, $seated,
            "payment_fits_session: '$status' " . ( $seated ? 'fills' : 'leaves free' )
            . ' the only seat';

        # Consumer 3: demotability.
        my $demoted = Registry::DAO::Enrollment->demote_to_waitlisted($db, {
            session_id => $session->id, student_id => $child->id,
            family_member_id => $child->id, parent_id => $parent->id,
            payment_id => $payment->id });
        my $now = $db->select('enrollments', ['status'],
            { session_id => $session->id, student_id => $child->id,
              payment_id => $payment->id })->hash->{status};
        # Grade the RETURN, not the resulting status. For an already-waitlisted
        # row the status cannot change, so a status assertion reads is(0,0) and
        # holds however demote_to_waitlisted behaves. The return is what the
        # settlement loop relies on to owe a share exactly once.
        is $demoted ? 1 : 0, $seated,
            "demote_to_waitlisted: '$status' reports "
            . ( $seated ? 'a transition' : 'no transition' );
        is $now, ( $seated ? 'waitlisted' : $status ),
            "demote_to_waitlisted: '$status' "
            . ( $seated ? 'lands on waitlisted' : 'is left alone' );
    }
};

done_testing;
