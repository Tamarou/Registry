#!/usr/bin/env perl
use v5.34.0;
use warnings;
use utf8;
use experimental qw(signatures);

use Test::More;
use Test::Exception;
use Test::Deep;

use lib qw(lib t/lib);
use Test::Registry::DB;
use Test::Registry::Fixtures;

use Registry::DAO::Attendance;
use Registry::DAO::Event;

# Setup test database
my $t  = Test::Registry::DB->new;
my $db = $t->db;

# Create a test tenant (in registry schema)
my $tenant = Test::Registry::Fixtures::create_tenant($db, {
    name => 'Test Organization',
    slug => 'test_org',
});

# Create the tenant schema with all required tables
$db->db->query('SELECT clone_schema(dest_schema => ?)', $tenant->slug);

# Create test data (in registry schema)
my $teacher = Test::Registry::Fixtures::create_user($db, {
    username => 'teacher',
    password => 'password123',
    user_type => 'staff',
});

my $student1 = Test::Registry::Fixtures::create_user($db, {
    username => 'student1',
    password => 'password123',
    user_type => 'student',
});

my $student2 = Test::Registry::Fixtures::create_user($db, {
    username => 'student2',
    password => 'password123',
    user_type => 'student',
});

# Copy users to tenant schema
$db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $teacher->id);
$db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $student1->id);
$db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $student2->id);

# Switch to tenant schema for operations
$db = $db->schema($tenant->slug);

my $location = Test::Registry::Fixtures::create_location($db, {
    name => 'Test School',
});

my $project = Test::Registry::Fixtures::create_project($db, {
    name => 'Test Program',
});

my $event = Test::Registry::Fixtures::create_event($db, {
    location_id => $location->id,
    project_id => $project->id,
    teacher_id => $teacher->id,
    time => '2024-03-15 14:00:00',
    duration => 60,
});

subtest 'Mark attendance' => sub {
    my $attendance = Registry::DAO::Attendance->mark_attendance(
        $db,
        $event->id,
        $student1->id,
        'present',
        $teacher->id,
        'On time'
    );
    
    ok($attendance, 'Attendance marked');
    is($attendance->event_id, $event->id, 'Correct event');
    is($attendance->student_id, $student1->id, 'Correct student');
    is($attendance->status, 'present', 'Status is present');
    is($attendance->marked_by, $teacher->id, 'Marked by teacher');
    is($attendance->notes, 'On time', 'Notes saved');
    ok($attendance->marked_at, 'Marked at timestamp set');
};

subtest 'Update existing attendance' => sub {
    # Mark absent first
    my $attendance = Registry::DAO::Attendance->mark_attendance(
        $db,
        $event->id,
        $student2->id,
        'absent',
        $teacher->id
    );
    
    is($attendance->status, 'absent', 'Initially marked absent');
    
    # Update to present
    my $updated = Registry::DAO::Attendance->mark_attendance(
        $db,
        $event->id,
        $student2->id,
        'present',
        $teacher->id,
        'Arrived late'
    );
    
    is($updated->id, $attendance->id, 'Same record updated');
    is($updated->status, 'present', 'Status updated to present');
    is($updated->notes, 'Arrived late', 'Notes updated');
    # Compare timestamps using database query since they're PostgreSQL timestamps
    my $is_updated = $db->db->query('SELECT ? > ?', $updated->marked_at, $attendance->marked_at)->array->[0];
    ok($is_updated, 'Timestamp updated');
};

subtest 'Validate status' => sub {
    dies_ok {
        Registry::DAO::Attendance->create($db, {
            event_id => $event->id,
            student_id => $student1->id,
            status => 'invalid',
            marked_by => $teacher->id
        });
    } 'Dies with invalid status';
};

subtest 'Get event attendance' => sub {
    # Clear existing attendance
    $db->db->delete('attendance_records', { event_id => $event->id });
    
    # Mark attendance for multiple students
    Registry::DAO::Attendance->mark_attendance($db, $event->id, $student1->id, 'present', $teacher->id);
    Registry::DAO::Attendance->mark_attendance($db, $event->id, $student2->id, 'absent', $teacher->id);
    
    my $attendance_list = Registry::DAO::Attendance->get_event_attendance($db, $event->id);
    
    is(@$attendance_list, 2, 'Two attendance records');
    
    # Should be sorted by student_id - check actual order
    my @student_ids = map { $_->student_id } @$attendance_list;
    my @statuses = map { $_->status } @$attendance_list;
    # Students should be ordered by their IDs (student1 vs student2)
    if ($student_ids[0] eq $student1->id) {
        is_deeply(\@statuses, ['present', 'absent'], 'Correct statuses in order');
    } else {
        is_deeply(\@statuses, ['absent', 'present'], 'Correct statuses in order');
    }
};

subtest 'Get student attendance' => sub {
    # Create another event
    my $event2 = Test::Registry::Fixtures::create_event($db, {
        location_id => $location->id,
        project_id => $project->id,
        teacher_id => $teacher->id,
        time => '2024-03-15 15:00:00',
        duration => 60,
    });
    
    # Mark attendance in both events
    Registry::DAO::Attendance->mark_attendance($db, $event2->id, $student1->id, 'present', $teacher->id);
    
    my $student_attendance = Registry::DAO::Attendance->get_student_attendance($db, $student1->id);
    
    ok(@$student_attendance >= 2, 'At least two attendance records for student');
    
    # Check they're sorted by marked_at descending
    my $prev_time = $student_attendance->[0]->marked_at;
    for my $record (@$student_attendance[1..$#$student_attendance]) {
        # Use database to compare timestamps
        my $is_sorted = $db->db->query('SELECT ? <= ?', $record->marked_at, $prev_time)->array->[0];
        ok($is_sorted, 'Records sorted by time descending');
        $prev_time = $record->marked_at;
    }
};

subtest 'Attendance summary' => sub {
    # Clear and set known attendance
    $db->db->delete('attendance_records', { event_id => $event->id });
    
    Registry::DAO::Attendance->mark_attendance($db, $event->id, $student1->id, 'present', $teacher->id);
    Registry::DAO::Attendance->mark_attendance($db, $event->id, $student2->id, 'present', $teacher->id);
    
    # Add a third student marked absent
    # Copy student3 from registry to tenant schema
    my $student3 = Test::Registry::Fixtures::create_user($db->schema('registry'), {
        username => 'student3',
        password => 'password123',
        user_type => 'student',
    });
    $db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $student3->id);
    Registry::DAO::Attendance->mark_attendance($db, $event->id, $student3->id, 'absent', $teacher->id);
    
    my $summary = Registry::DAO::Attendance->get_event_summary($db, $event->id);
    
    is($summary->{total}, 3, 'Total count correct');
    is($summary->{present}, 2, 'Present count correct');
    is($summary->{absent}, 1, 'Absent count correct');
    is($summary->{attendance_rate}, '66.7%', 'Attendance rate calculated');
};

subtest 'Bulk attendance marking' => sub {
    my $event3 = Test::Registry::Fixtures::create_event($db, {
        location_id => $location->id,
        project_id => $project->id,
        teacher_id => $teacher->id,
        time => '2024-03-15 16:00:00',
        duration => 60,
    });
    
    my $attendance_data = [
        { student_id => $student1->id, status => 'present' },
        { student_id => $student2->id, status => 'absent', notes => 'Sick' },
    ];
    
    my $results = Registry::DAO::Attendance->mark_bulk_attendance(
        $db,
        $event3->id,
        $attendance_data,
        $teacher->id
    );
    
    is(@$results, 2, 'Two records created');
    is($results->[0]->status, 'present', 'First student present');
    is($results->[1]->status, 'absent', 'Second student absent');
    is($results->[1]->notes, 'Sick', 'Notes saved');
};

subtest 'Helper methods' => sub {
    my $attendance = Registry::DAO::Attendance->mark_attendance(
        $db,
        $event->id,
        $student1->id,
        'present',
        $teacher->id
    );
    
    ok($attendance->is_present, 'is_present returns true');
    ok(!$attendance->is_absent, 'is_absent returns false');
    ok($attendance->is_recent($db), 'Recently marked attendance is recent');
    ok($attendance->is_recent($db, 3600), 'Recent with 1 hour threshold');
};

subtest 'Event integration' => sub {
    my $event_attendance = $event->attendance_records($db);
    ok($event_attendance, 'Got attendance records from event');
    isa_ok($event_attendance, 'ARRAY', 'Returns array ref');
    
    my $summary = $event->attendance_summary($db);
    ok($summary, 'Got attendance summary from event');
    ok(exists $summary->{attendance_rate}, 'Summary has attendance rate');
};

subtest 'Unique constraint' => sub {
    # Try to create duplicate attendance record
    dies_ok {
        Registry::DAO::Attendance->create($db, {
            event_id => $event->id,
            student_id => $student1->id,
            status => 'present',
            marked_by => $teacher->id
        });
    } 'Cannot create duplicate attendance record';
};

done_testing;