# ABOUTME: Tests MVP §6 -- a parent can see how many meetings their child attended.
# ABOUTME: The count a parent reads has to distinguish present from absent and from unmarked.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Family;
use Registry::DAO::Enrollment;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $loc = $dao->create(Location => {
    name => 'Attend Studio', slug => 'attend-studio', address_info => {}, metadata => {},
});
my $prog = $dao->create(Project => {
    status => 'published', name => 'Attend Camp', program_type_slug => 'summer-camp', metadata => {},
});
my $teacher = $dao->create(User => {
    username => 'attend_teacher', name => 'T', user_type => 'staff', email => 'at2@test.local',
});
my $parent = $dao->create(User => {
    username => 'attend_parent', name => 'Attend Parent', user_type => 'parent',
    email => 'ap2@test.local',
});
my $child = Registry::DAO::Family->add_child($db, $parent->id, {
    child_name => 'Attending Kid', birth_date => '2018-01-01', grade => '3',
    medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
});

my $session = $dao->create(Session => {
    name => 'Attend Week', start_date => '2026-01-01', end_date => '2026-12-31',
    status => 'published', capacity => 20,
    metadata => { project_id => $prog->id, location_id => $loc->id },
});

# Three meetings, which is what makes a count meaningful: a fraction cannot be
# checked against a session that meets once.
my @events;
for my $hour ( 9, 11, 13 ) {
    my $event = $dao->create(Event => {
        time => sprintf('2026-06-15 %02d:00:00', $hour), duration => 60,
        location_id => $loc->id, project_id => $prog->id,
        teacher_id => $teacher->id, capacity => 20, metadata => {},
    });
    $session->add_events($db, $event->id);
    push @events, $event;
}

Registry::DAO::Enrollment->create($db, {
    session_id => $session->id, family_member_id => $child->id,
    student_id => $child->id, parent_id => $parent->id, status => 'active',
});

sub dashboard_row () {
    my $rows = Registry::DAO::Enrollment->get_active_for_parent($db, $parent->id);
    return ( grep { $_->{session_id} eq $session->id } @$rows )[0];
}

subtest 'before any attendance is taken the parent sees none of three' => sub {
    my $row = dashboard_row();
    ok $row, 'the enrolment is on the parent dashboard';
    is $row->{total_events}, 3, 'three meetings in the session';
    is $row->{attended_events}, 0, 'none attended yet';
    is $row->{child_name}, 'Attending Kid', 'named for the child';
    is $row->{program_name}, 'Attend Camp', 'and the programme';
};

subtest 'a present mark counts and an absent one does not' => sub {
    # Present at the first, absent at the second, unmarked at the third. Two of
    # the three are recorded, and only one of them is attendance.
    $db->insert('attendance_records', {
        event_id => $events[0]->id, student_id => $child->id,
        status => 'present', marked_by => $teacher->id,
    });
    $db->insert('attendance_records', {
        event_id => $events[1]->id, student_id => $child->id,
        status => 'absent', marked_by => $teacher->id,
    });

    my $row = dashboard_row();
    is $row->{total_events}, 3, 'still three meetings';
    is $row->{attended_events}, 1,
        'one attended -- an absence is a record, not an attendance';
};

subtest 'attendance for another child does not count towards this one' => sub {
    my $sibling = Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => 'Other Kid', birth_date => '2017-01-01', grade => '4',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
    });
    $db->insert('attendance_records', {
        event_id => $events[2]->id, student_id => $sibling->id,
        status => 'present', marked_by => $teacher->id,
    });

    my $row = dashboard_row();
    is $row->{attended_events}, 1,
        'the sibling being present at the third meeting is not this child attending';
};

subtest 'a full house reads three of three' => sub {
    $db->insert('attendance_records', {
        event_id => $events[2]->id, student_id => $child->id,
        status => 'present', marked_by => $teacher->id,
    });
    $db->update('attendance_records', { status => 'present' },
        { event_id => $events[1]->id, student_id => $child->id });

    my $row = dashboard_row();
    is $row->{attended_events}, 3, 'all three now counted';
    is $row->{total_events}, 3, 'out of three -- not multiplied by the join';
};

done_testing;
