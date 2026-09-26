# ABOUTME: Tests MVP §9 -- a parent's drop records a refund REQUEST and refunds nothing.
# ABOUTME: "No automatic refunds (Morgan can override)", owned by no suite before #395.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Family;
use Registry::DAO::Enrollment;
use Registry::DAO::DropRequest;
use Registry::DAO::Payment;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

sub days_from_now ($n) {
    my @t = localtime( time + $n * 86_400 );
    return sprintf '%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3];
}

my $loc = $dao->create(Location => {
    name => 'Drop Studio', slug => 'drop-studio', address_info => {}, metadata => {},
});
my $prog = $dao->create(Project => {
    status => 'published', name => 'Drop Camp', program_type_slug => 'summer-camp', metadata => {},
});
my $teacher = $dao->create(User => {
    username => 'drop_teacher', name => 'T', user_type => 'staff', email => 'dt@test.local',
});
my $parent = $dao->create(User => {
    username => 'drop_parent', name => 'Drop Parent', user_type => 'parent',
    email => 'dp@test.local',
});
my $child = Registry::DAO::Family->add_child($db, $parent->id, {
    child_name => 'Dropping Kid', birth_date => '2018-01-01', grade => '3',
    medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
});

# The acting user as the workflow carries it: a plain hash off the session.
my $acting = { id => $parent->id, user_type => 'parent' };

my $hour = 9;
sub make_session ( $name, $start, $end ) {
    my $session = $dao->create(Session => {
        name => $name, start_date => $start, end_date => $end,
        status => 'published', capacity => 20, metadata => {},
    });
    my $event = $dao->create(Event => {
        time => "$start " . sprintf('%02d:00:00', $hour++), duration => 60,
        location_id => $loc->id, project_id => $prog->id,
        teacher_id => $teacher->id, capacity => 20, metadata => {},
    });
    $session->add_events($db, $event->id);
    return $session;
}

sub paid_enrollment ($session) {
    my $payment = Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => 30000, status => 'completed',
        metadata => {},
    });
    my $enrollment = Registry::DAO::Enrollment->create($db, {
        session_id => $session->id, family_member_id => $child->id,
        student_id => $child->id, parent_id => $parent->id, status => 'active',
    });
    return ( $enrollment, $payment );
}

subtest 'a drop before the session starts is immediate and refunds nothing' => sub {
    # Self-service, per the spec: the parent may drop a session that has not
    # begun without waiting for anybody.
    my $session = make_session( 'Not Started Yet', days_from_now(20), days_from_now(27) );
    my ( $enrollment, $payment ) = paid_enrollment($session);

    my $result = Registry::DAO::DropRequest->request_for_enrollment(
        $db, $enrollment->id, $acting, 'Moving away', 1 );

    ok $result->{success}, 'the drop succeeds';
    ok $result->{immediate}, 'and takes effect immediately';

    # The refund is a REQUEST. Nothing about the payment changes -- no refund is
    # issued, no debt is recorded -- because the studio decides.
    my $row = $db->select('payments', '*', { id => $payment->id })->hash;
    is $row->{status}, 'completed', 'the payment is untouched';
    is $row->{refunded_cents}, 0, 'nothing has been refunded';
    is $row->{refund_owed_cents}, 0, 'and nothing is even recorded as owed';
};

subtest 'a drop after the session starts waits for the studio' => sub {
    my $session = make_session( 'Already Started', days_from_now(-3), days_from_now(10) );
    my ( $enrollment, $payment ) = paid_enrollment($session);

    my $result = Registry::DAO::DropRequest->request_for_enrollment(
        $db, $enrollment->id, $acting, 'Child is unwell', 1 );

    ok $result->{success}, 'the request is accepted';
    ok !$result->{immediate}, 'but is not acted on immediately';
    ok $result->{drop_request}, 'a drop request row exists for the studio to review';

    my $row = $db->select('drop_requests', '*',
        { id => $result->{drop_request}->id })->hash;
    is $row->{status}, 'pending', 'and it is waiting';
    ok $row->{refund_requested}, 'carrying the refund the parent asked for';
    is $row->{reason}, 'Child is unwell', 'and the reason they gave';

    # Still no money moved. This is the whole of §9: the request is recorded, the
    # refund is not granted, and a human decides.
    my $paid = $db->select('payments', '*', { id => $payment->id })->hash;
    is $paid->{refunded_cents}, 0, 'no refund was issued';
    is $paid->{refund_owed_cents}, 0, 'and none was promised';
};

subtest 'a drop with no refund asked for records that too' => sub {
    my $session = make_session( 'No Refund Wanted', days_from_now(-3), days_from_now(10) );
    my ( $enrollment ) = paid_enrollment($session);

    my $result = Registry::DAO::DropRequest->request_for_enrollment(
        $db, $enrollment->id, $acting, 'Schedule clash', 0 );

    my $row = $db->select('drop_requests', '*',
        { id => $result->{drop_request}->id })->hash;
    ok !$row->{refund_requested},
        'the flag distinguishes a parent who asked from one who did not';
};

subtest 'a parent cannot drop a child who is not theirs' => sub {
    my $session = make_session( 'Someone Elses', days_from_now(20), days_from_now(27) );
    my $stranger = $dao->create(User => {
        username => 'stranger_parent', name => 'Stranger', user_type => 'parent',
        email => 'sp@test.local',
    });
    my ( $enrollment ) = paid_enrollment($session);

    my $result = Registry::DAO::DropRequest->request_for_enrollment(
        $db, $enrollment->id, { id => $stranger->id, user_type => 'parent' },
        'Not mine', 1 );

    like $result->{error}, qr/do not own/, 'the request is refused';

    my $still = Registry::DAO::Enrollment->find($db, { id => $enrollment->id });
    is $still->status, 'active', 'and the enrollment is untouched';
};

done_testing;
