#!/usr/bin/env perl
# ABOUTME: Tests for teacher dashboard completeness.
# ABOUTME: Verifies attendance persistence, multiple events per day, and substitute teacher access.

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;

use Registry::DAO;
use Registry::DAO::User;
use Registry::DAO::Session;
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Family;
use Registry::DAO::Enrollment;
use Registry::DAO::Attendance;
use DateTime;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

# --- Setup ---

my $location = $dao->create(Location => {
    name => 'Teacher Complete Studio', slug => 'teacher-complete',
    address_info => { city => 'Orlando' }, metadata => {},
});

my $program = $dao->create(Project => { status => 'published',
    name => 'Teacher Complete Camp', metadata => {},
});

my $teacher1 = $dao->create(User => {
    username => 'tc_teacher1', name => 'Primary Teacher',
    user_type => 'staff', email => 'teacher1@test.com',
});

my $teacher2 = $dao->create(User => {
    username => 'tc_teacher2', name => 'Substitute Teacher',
    user_type => 'staff', email => 'teacher2@test.com',
});

my $session = $dao->create(Session => {
    name => 'TC Week 1', start_date => '2026-06-01', end_date => '2026-06-05',
    status => 'published', capacity => 16, metadata => {},
});

# Two events on the same day
my $morning_event = $dao->create(Event => {
    time => '2026-06-01 09:00:00', duration => 180,
    location_id => $location->id, project_id => $program->id,
    teacher_id => $teacher1->id, capacity => 16, metadata => {},
});

my $afternoon_event = $dao->create(Event => {
    time => '2026-06-01 13:00:00', duration => 180,
    location_id => $location->id, project_id => $program->id,
    teacher_id => $teacher1->id, capacity => 16, metadata => {},
});

$session->add_events($dao->db, $morning_event->id);
$session->add_events($dao->db, $afternoon_event->id);

# Enrolled student (using parent user ID for attendance FK)
my $parent = $dao->create(User => {
    username => 'tc_parent', name => 'TC Parent',
    user_type => 'parent', email => 'tc_parent@test.com',
});

my $child = Registry::DAO::Family->add_child($dao->db, $parent->id, {
    child_name => 'TC Kid', birth_date => '2018-01-01', grade => '3',
    medical_info => {}, emergency_contact => { name => 'P', phone => '555' },
});

Registry::DAO::Enrollment->create($dao->db, {
    session_id => $session->id, family_member_id => $child->id,
    parent_id => $parent->id, status => 'active',
});

# ============================================================
# Test: Attendance records persist and can be updated
# ============================================================
subtest 'attendance records persist and update correctly' => sub {
    # Mark present
    Registry::DAO::Attendance->mark_attendance(
        $dao->db, $morning_event->id, $parent->id, 'present', $teacher1->id,
    );

    my $records = Registry::DAO::Attendance->get_event_attendance(
        $dao->db, $morning_event->id,
    );
    ok scalar @$records >= 1, 'Attendance record persisted';

    my ($record) = grep { $_->student_id eq $parent->id } @$records;
    is $record->status, 'present', 'Status is present';

    # Update to absent
    Registry::DAO::Attendance->mark_attendance(
        $dao->db, $morning_event->id, $parent->id, 'absent', $teacher1->id,
    );

    $records = Registry::DAO::Attendance->get_event_attendance(
        $dao->db, $morning_event->id,
    );
    ($record) = grep { $_->student_id eq $parent->id } @$records;
    is $record->status, 'absent', 'Status updated to absent';
};

# ============================================================
# Test: Multiple events same day tracked independently
# ============================================================
subtest 'multiple events same day tracked independently' => sub {
    Registry::DAO::Attendance->mark_attendance(
        $dao->db, $morning_event->id, $parent->id, 'present', $teacher1->id,
    );
    Registry::DAO::Attendance->mark_attendance(
        $dao->db, $afternoon_event->id, $parent->id, 'absent', $teacher1->id,
    );

    my $am_records = Registry::DAO::Attendance->get_event_attendance(
        $dao->db, $morning_event->id,
    );
    my $pm_records = Registry::DAO::Attendance->get_event_attendance(
        $dao->db, $afternoon_event->id,
    );

    my ($am) = grep { $_->student_id eq $parent->id } @$am_records;
    my ($pm) = grep { $_->student_id eq $parent->id } @$pm_records;

    ok $am, 'Morning record found';
    ok $pm, 'Afternoon record found';
    is $am->status, 'present', 'Morning: present';
    is $pm->status, 'absent', 'Afternoon: absent (independent)';
};

# ============================================================
# Test: Teacher events for date query
# ============================================================
subtest 'teacher sees multiple events on same day' => sub {
    my $events = Registry::DAO::Event->get_teacher_events_for_date(
        $dao->db, $teacher1->id, '2026-06-01',
    );

    ok scalar @$events >= 2, 'Teacher has 2+ events on 2026-06-01';
};

# ============================================================
# Test: Substitute teacher can record attendance
# ============================================================
subtest 'substitute teacher can mark attendance' => sub {
    Registry::DAO::Attendance->mark_attendance(
        $dao->db, $afternoon_event->id, $parent->id, 'present', $teacher2->id,
    );

    my $records = Registry::DAO::Attendance->get_event_attendance(
        $dao->db, $afternoon_event->id,
    );

    my ($record) = grep { $_->student_id eq $parent->id } @$records;
    is $record->status, 'present', 'Substitute teacher updated attendance';
};

done_testing;
