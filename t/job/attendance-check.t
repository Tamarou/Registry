#!/usr/bin/env perl

use 5.40.2;
use experimental qw( try );

use Test::More;
use Test::Registry::DB;
use Registry::Job::AttendanceCheck;
use Registry::DAO::User;
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Session;
use Registry::DAO::Enrollment;
use Registry::DAO::Notification;
use Registry::DAO::UserPreference;
use DateTime;

my $db_helper = Test::Registry::DB->new;
my $dao = $db_helper->setup_test_database;
my $db = $dao->db;

# Deploy all necessary schemas
$db_helper->deploy_sqitch_changes([
    'events-and-sessions',
    'attendance-tracking', 
    'notifications-and-preferences',
    'summer-camp-module'
]);

# Create test data
sub setup_test_data {
    # Create a teacher
    my $teacher = Registry::DAO::User->create($db, {
        username => 'teacher1',
        passhash => 'fake_hash'
    });
    
    $db->insert('user_profiles', {
        user_id => $teacher->id,
        email => 'teacher1@example.com',
        name => 'Test Teacher'
    });

    # Create a student
    my $student = Registry::DAO::User->create($db, {
        username => 'student1',
        passhash => 'fake_hash'
    });

    # Create a location
    my $location = Registry::DAO::Location->create($db, {
        name => 'Test Location',
        slug => 'test-location',
        address_info => { street => '123 Test St' }
    });

    # Create a project
    my $project = Registry::DAO::Project->create($db, {
        name => 'Test Project',
        slug => 'test-project'
    });

    # Create a session
    my $session = Registry::DAO::Session->create($db, {
        name => 'Test Session',
        slug => 'test-session'
    });

    # Create enrollment
    my $enrollment = Registry::DAO::Enrollment->create($db, {
        user_id => $student->id,
        session_id => $session->id,
        status => 'active'
    });

    return {
        teacher => $teacher,
        student => $student,
        location => $location,
        project => $project,
        session => $session,
        enrollment => $enrollment
    };
}

subtest 'Find events missing attendance' => sub {
    my $data = setup_test_data();
    
    # Create an event that started 10 minutes ago (should trigger notification)
    my $past_time = DateTime->now->subtract(minutes => 10)->iso8601;
    my $event_missing = Registry::DAO::Event->create($db, {
        location_id => $data->{location}->id,
        project_id => $data->{project}->id,
        teacher_id => $data->{teacher}->id,
        metadata => {
            title => 'Event Missing Attendance',
            start_time => $past_time,
            end_time => DateTime->now->add(minutes => 50)->iso8601
        }
    });

    # Link session to project for enrollment tracking
    $db->insert('session_events', {
        session_id => $data->{session}->id,
        event_id => $event_missing->id
    });

    # Create another event that started 20 minutes ago but has attendance
    my $past_time_2 = DateTime->now->subtract(minutes => 20)->iso8601;
    my $event_with_attendance = Registry::DAO::Event->create($db, {
        location_id => $data->{location}->id,
        project_id => $data->{project}->id,
        teacher_id => $data->{teacher}->id,
        metadata => {
            title => 'Event With Attendance',
            start_time => $past_time_2,
            end_time => DateTime->now->add(minutes => 40)->iso8601
        }
    });

    # Add attendance record for this event
    $db->insert('attendance_records', {
        event_id => $event_with_attendance->id,
        student_id => $data->{student}->id,
        status => 'present',
        marked_by => $data->{teacher}->id
    });

    # Test the job's query method
    my $job_class = Registry::Job::AttendanceCheck->new;
    my $missing_events = $job_class->find_events_missing_attendance($db);

    is(scalar @$missing_events, 1, 'Found one event missing attendance');
    is($missing_events->[0]{id}, $event_missing->id, 'Correct event identified as missing attendance');
    is($missing_events->[0]{title}, 'Event Missing Attendance', 'Event title retrieved correctly');
};

subtest 'Find events starting soon' => sub {
    my $data = setup_test_data();
    
    # Create an event starting in 3 minutes (should trigger reminder)
    my $soon_time = DateTime->now->add(minutes => 3)->iso8601;
    my $event_starting_soon = Registry::DAO::Event->create($db, {
        location_id => $data->{location}->id,
        project_id => $data->{project}->id,
        teacher_id => $data->{teacher}->id,
        metadata => {
            title => 'Event Starting Soon',
            start_time => $soon_time,
            end_time => DateTime->now->add(minutes => 63)->iso8601
        }
    });

    # Link session to project for enrollment tracking
    $db->insert('session_events', {
        session_id => $data->{session}->id,
        event_id => $event_starting_soon->id
    });

    # Create an event starting in 10 minutes (should not trigger)
    my $later_time = DateTime->now->add(minutes => 10)->iso8601;
    my $event_starting_later = Registry::DAO::Event->create($db, {
        location_id => $data->{location}->id,
        project_id => $data->{project}->id,
        teacher_id => $data->{teacher}->id,
        metadata => {
            title => 'Event Starting Later',
            start_time => $later_time,
            end_time => DateTime->now->add(minutes => 70)->iso8601
        }
    });

    # Test the job's query method
    my $job_class = Registry::Job::AttendanceCheck->new;
    my $soon_events = $job_class->find_events_starting_soon($db);

    is(scalar @$soon_events, 1, 'Found one event starting soon');
    is($soon_events->[0]{id}, $event_starting_soon->id, 'Correct event identified as starting soon');
    is($soon_events->[0]{title}, 'Event Starting Soon', 'Event title retrieved correctly');
};

subtest 'Job execution with notifications' => sub {
    # Clean up any existing notifications
    $db->delete('notifications', {});
    
    my $data = setup_test_data();
    
    # Set up user preferences (defaults should allow notifications)
    Registry::DAO::UserPreference->get_or_create($db, $data->{teacher}->id, 'notifications', {
        attendance_missing => { email => 1, in_app => 1 },
        attendance_reminder => { email => 1, in_app => 1 }
    });

    # Create an event missing attendance
    my $past_time = DateTime->now->subtract(minutes => 10)->iso8601;
    my $event_missing = Registry::DAO::Event->create($db, {
        location_id => $data->{location}->id,
        project_id => $data->{project}->id,
        teacher_id => $data->{teacher}->id,
        metadata => {
            title => 'Event Missing Attendance',
            start_time => $past_time,
            end_time => DateTime->now->add(minutes => 50)->iso8601
        }
    });

    # Link session to project for enrollment tracking
    $db->insert('session_events', {
        session_id => $data->{session}->id,
        event_id => $event_missing->id
    });

    # Create an event starting soon
    my $soon_time = DateTime->now->add(minutes => 3)->iso8601;
    my $event_starting_soon = Registry::DAO::Event->create($db, {
        location_id => $data->{location}->id,
        project_id => $data->{project}->id,
        teacher_id => $data->{teacher}->id,
        metadata => {
            title => 'Event Starting Soon',
            start_time => $soon_time,
            end_time => DateTime->now->add(minutes => 63)->iso8601
        }
    });

    # Link session to project for enrollment tracking
    $db->insert('session_events', {
        session_id => $data->{session}->id,
        event_id => $event_starting_soon->id
    });

    # Mock job object for testing
    my $mock_job = bless {
        app => bless {
            log => bless {}, 'MockLogger',
            dao => sub { $dao }
        }, 'MockApp'
    }, 'MockJob';
    
    # Mock logger methods
    {
        package MockLogger;
        sub info { shift; say "INFO: @_" if $ENV{TEST_VERBOSE} }
        sub debug { shift; say "DEBUG: @_" if $ENV{TEST_VERBOSE} }
        sub error { shift; say "ERROR: @_" if $ENV{TEST_VERBOSE} }
    }
    
    # Mock app method
    {
        package MockApp;
        sub dao { $dao }
        sub log { shift->{log} }
    }
    
    # Mock job methods
    {
        package MockJob;
        sub app { shift->{app} }
    }

    # Create and run the job
    my $job_instance = Registry::Job::AttendanceCheck->new;
    
    # Test just the tenant checking logic
    $job_instance->check_tenant_attendance($mock_job, $db, 'public');

    # Check that notifications were created
    my $notifications = $db->select('notifications', '*', {
        user_id => $data->{teacher}->id
    })->hashes->to_array;

    # Should have 4 notifications: 2 for missing attendance (email + in_app) + 2 for reminder (email + in_app)
    is(scalar @$notifications, 4, 'Created expected number of notifications');

    # Check notification types
    my @missing_notifications = grep { $_->{type} eq 'attendance_missing' } @$notifications;
    my @reminder_notifications = grep { $_->{type} eq 'attendance_reminder' } @$notifications;

    is(scalar @missing_notifications, 2, 'Created 2 attendance missing notifications');
    is(scalar @reminder_notifications, 2, 'Created 2 attendance reminder notifications');

    # Check channels
    my @email_notifications = grep { $_->{channel} eq 'email' } @$notifications;
    my @in_app_notifications = grep { $_->{channel} eq 'in_app' } @$notifications;

    is(scalar @email_notifications, 2, 'Created 2 email notifications');
    is(scalar @in_app_notifications, 2, 'Created 2 in-app notifications');

    # Check that in-app notifications are marked as sent
    for my $notification (@in_app_notifications) {
        ok(defined $notification->{sent_at}, 'In-app notification marked as sent');
    }
};

subtest 'Prevent duplicate reminder notifications' => sub {
    # Clean up any existing notifications
    $db->delete('notifications', {});
    
    my $data = setup_test_data();
    
    # Create an event starting soon
    my $soon_time = DateTime->now->add(minutes => 3)->iso8601;
    my $event_starting_soon = Registry::DAO::Event->create($db, {
        location_id => $data->{location}->id,
        project_id => $data->{project}->id,
        teacher_id => $data->{teacher}->id,
        metadata => {
            title => 'Event Starting Soon',
            start_time => $soon_time,
            end_time => DateTime->now->add(minutes => 63)->iso8601
        }
    });

    # Link session to project
    $db->insert('session_events', {
        session_id => $data->{session}->id,
        event_id => $event_starting_soon->id
    });

    # Manually create a reminder notification
    Registry::DAO::Notification->create($db, {
        user_id => $data->{teacher}->id,
        type => 'attendance_reminder',
        channel => 'email',
        subject => 'Existing Reminder',
        message => 'Existing reminder message',
        metadata => { event_id => $event_starting_soon->id }
    });

    # Mock job and run check
    my $mock_job = bless {
        app => bless {
            log => bless {}, 'MockLogger',
            dao => sub { $dao }
        }, 'MockApp'
    }, 'MockJob';

    my $job_instance = Registry::Job::AttendanceCheck->new;
    $job_instance->check_tenant_attendance($mock_job, $db, 'public');

    # Should still only have 1 reminder notification (no duplicates)
    my $reminder_count = $db->select('notifications', 'count(*)', {
        user_id => $data->{teacher}->id,
        type => 'attendance_reminder',
        'metadata->event_id' => $event_starting_soon->id
    })->array->[0];

    is($reminder_count, 1, 'No duplicate reminder notifications created');
};

$db_helper->cleanup_test_database;
done_testing;