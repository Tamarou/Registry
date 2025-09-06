#!/usr/bin/env perl

use 5.40.2;
use experimental qw( try );

# Set up test email transport BEFORE loading any modules that might use Email::Sender
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test'; }

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::Job::AttendanceCheck;
use Registry::Job::WorkflowExecutor;
use Registry::DAO::User;
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Session;
use Registry::DAO::Enrollment;
use Registry::DAO::Notification;
use Registry::DAO::UserPreference;
use Registry::DAO::Workflow;
use DateTime;

my $db_helper = Test::Registry::DB->new;
my $dao = $db_helper->setup_test_database;
my $db = $dao->db;

# All schemas are already deployed by Test::Registry::DB->new

# Import workflows for testing
system('carton exec ./registry workflow import registry') == 0 
    or die "Failed to import workflows for testing";

# Create test data
sub setup_test_data {
    # Create a teacher with unique username (using more unique identifier)
    my $unique_id = time() . '_' . $$ . '_' . int(rand(999999));
    my $teacher = Registry::DAO::User->create($db, {
        username => 'teacher1_' . $unique_id,
        passhash => 'fake_hash'
    });
    
    $db->insert('user_profiles', {
        user_id => $teacher->id,
        email => 'teacher1_' . $unique_id . '@example.com',
        name => 'Test Teacher'
    });

    # Create a student
    my $student = Registry::DAO::User->create($db, {
        username => 'student1_' . $unique_id,
        passhash => 'fake_hash'
    });

    # Create a location
    my $location = Registry::DAO::Location->create($db, {
        name => 'Test Location ' . $unique_id,
        slug => 'test-location-' . $unique_id,
        address_info => { street => '123 Test St' }
    });

    # Create a project
    my $project = Registry::DAO::Project->create($db, {
        name => 'Test Project ' . $unique_id,
        slug => 'test-project-' . $unique_id
    });

    # Create a session
    my $session = Registry::DAO::Session->create($db, {
        name => 'Test Session ' . $unique_id,
        slug => 'test-session-' . $unique_id
    });

    # Create enrollment
    my $enrollment = Registry::DAO::Enrollment->create($db, {
        student_id => $student->id,
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
    my $past_time = DateTime->now->subtract(minutes => 10);
    my $event_missing = Registry::DAO::Event->create($db, {
        location_id => $data->{location}->id,
        project_id => $data->{project}->id,
        teacher_id => $data->{teacher}->id,
        start_time => $past_time,
        end_time => DateTime->now->add(minutes => 50),
        metadata => {
            title => 'Event Missing Attendance'
        }
    });

    # Link session to project for enrollment tracking
    $db->insert('session_events', {
        session_id => $data->{session}->id,
        event_id => $event_missing->id
    });

    # Create another event that started 20 minutes ago but has attendance
    my $past_time_2 = DateTime->now->subtract(minutes => 20);
    my $event_with_attendance = Registry::DAO::Event->create($db, {
        location_id => $data->{location}->id,
        project_id => $data->{project}->id,
        teacher_id => $data->{teacher}->id,
        start_time => $past_time_2,
        end_time => DateTime->now->add(minutes => 40),
        metadata => {
            title => 'Event With Attendance'
        }
    });

    # Add attendance record for this event
    $db->insert('attendance_records', {
        event_id => $event_with_attendance->id,
        student_id => $data->{student}->id,
        status => 'present',
        marked_by => $data->{teacher}->id
    });

    # Test the DAO method that the job uses
    my $missing_events = Registry::DAO::Event->find_events_missing_attendance($db);

    is(scalar @$missing_events, 1, 'Found one event missing attendance');
    is($missing_events->[0]{id}, $event_missing->id, 'Correct event identified as missing attendance');
    is($missing_events->[0]{title}, 'Event Missing Attendance', 'Event title retrieved correctly');
};

subtest 'Find events starting soon' => sub {
    my $data = setup_test_data();
    
    # Create an event starting in 3 minutes (should trigger reminder)
    my $soon_time = DateTime->now->add(minutes => 3);
    my $event_starting_soon = Registry::DAO::Event->create($db, {
        location_id => $data->{location}->id,
        project_id => $data->{project}->id,
        teacher_id => $data->{teacher}->id,
        start_time => $soon_time,
        end_time => DateTime->now->add(minutes => 63),
        metadata => {
            title => 'Event Starting Soon'
        }
    });

    # Link session to project for enrollment tracking
    $db->insert('session_events', {
        session_id => $data->{session}->id,
        event_id => $event_starting_soon->id
    });

    # Create an event starting in 10 minutes (should not trigger)
    my $later_time = DateTime->now->add(minutes => 10);
    my $event_starting_later = Registry::DAO::Event->create($db, {
        location_id => $data->{location}->id,
        project_id => $data->{project}->id,
        teacher_id => $data->{teacher}->id,
        start_time => $later_time,
        end_time => DateTime->now->add(minutes => 70),
        metadata => {
            title => 'Event Starting Later'
        }
    });

    # Test the job's query method
    my $soon_events = Registry::DAO::Event->find_events_starting_soon($db);

    is(scalar @$soon_events, 1, 'Found one event starting soon');
    is($soon_events->[0]{id}, $event_starting_soon->id, 'Correct event identified as starting soon');
    is($soon_events->[0]{title}, 'Event Starting Soon', 'Event title retrieved correctly');
};

subtest 'Job execution with notifications' => sub {
    # Clean up any existing notifications
    $db->delete('notifications', {});
    
    my $data = setup_test_data();
    
    # Set up user preferences (defaults should allow notifications)
    eval {
        Registry::DAO::UserPreference->get_or_create($db, $data->{teacher}->id, 'notifications', {
            attendance_missing => { email => 1, in_app => 1 },
            attendance_reminder => { email => 1, in_app => 1 }
        });
    };
    if ($@) {
        diag("Error creating user preferences: $@");
        return;
    }

    # Create an event missing attendance
    my $past_time = DateTime->now->subtract(minutes => 10);
    my $event_missing = Registry::DAO::Event->create($db, {
        location_id => $data->{location}->id,
        project_id => $data->{project}->id,
        teacher_id => $data->{teacher}->id,
        start_time => $past_time,
        end_time => DateTime->now->add(minutes => 50),
        metadata => {
            title => 'Event Missing Attendance'
        }
    });

    # Link session to project for enrollment tracking
    $db->insert('session_events', {
        session_id => $data->{session}->id,
        event_id => $event_missing->id
    });

    # Create an event starting soon
    my $soon_time = DateTime->now->add(minutes => 3);
    my $event_starting_soon = Registry::DAO::Event->create($db, {
        location_id => $data->{location}->id,
        project_id => $data->{project}->id,
        teacher_id => $data->{teacher}->id,
        start_time => $soon_time,
        end_time => DateTime->now->add(minutes => 63),
        metadata => {
            title => 'Event Starting Soon'
        }
    });

    # Link session to project for enrollment tracking
    $db->insert('session_events', {
        session_id => $data->{session}->id,
        event_id => $event_starting_soon->id
    });

    # Mock minion for scheduling
    my $scheduled_jobs = [];
    my $mock_minion = bless {
        enqueue => sub {
            my ($self, $task, $args, $opts) = @_;
            push @$scheduled_jobs, { task => $task, args => $args, opts => $opts };
            return 'job_id_123';
        }
    }, 'MockMinion';
    
    # Mock job object for testing
    my $mock_logger = bless {}, 'MockLogger';
    my $mock_app = bless {
        log => $mock_logger,
        dao => sub { $dao },
        minion => $mock_minion
    }, 'MockApp';
    my $mock_job = bless {
        app => $mock_app
    }, 'MockJob';
    
    # Mock logger methods
    {
        package MockLogger;
        sub info { shift; say "INFO: @_" if $ENV{TEST_VERBOSE} }
        sub debug { shift; say "DEBUG: @_" if $ENV{TEST_VERBOSE} }
        sub error { shift; say "ERROR: @_" if $ENV{TEST_VERBOSE} }
    }
    
    # Mock app methods
    {
        package MockApp;
        sub dao { $dao }
        sub log { shift->{log} }
        sub minion { shift->{minion} }
    }
    
    # Mock job methods
    {
        package MockJob;
        sub app { shift->{app} }
        sub id { 'test_job_123' }
        sub fail { shift; warn "Job failed: @_" }
    }

    # Test both the specific job and generic executor
    my $job_instance = Registry::Job::AttendanceCheck->new;
    $job_instance->run($mock_job);
    
    # Also test direct workflow executor
    my $executor = Registry::Job::WorkflowExecutor->new;
    my $workflow_opts = {
        workflow_slug => 'attendance-check',
        context => {},
        reschedule => { enabled => 0 }
    };
    $executor->run($mock_job, $workflow_opts);

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
    my $soon_time = DateTime->now->add(minutes => 3);
    my $event_starting_soon = Registry::DAO::Event->create($db, {
        location_id => $data->{location}->id,
        project_id => $data->{project}->id,
        teacher_id => $data->{teacher}->id,
        start_time => $soon_time,
        end_time => DateTime->now->add(minutes => 63),
        metadata => {
            title => 'Event Starting Soon'
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

    # Mock minion for scheduling
    my $scheduled_jobs2 = [];
    my $mock_minion2 = bless {
        enqueue => sub {
            my ($self, $task, $args, $opts) = @_;
            push @$scheduled_jobs2, { task => $task, args => $args, opts => $opts };
            return 'job_id_456';
        }
    }, 'MockMinion';
    
    # Mock job and run check
    my $mock_logger2 = bless {}, 'MockLogger';
    my $mock_app2 = bless {
        log => $mock_logger2,
        dao => sub { $dao },
        minion => $mock_minion2
    }, 'MockApp';
    my $mock_job2 = bless {
        app => $mock_app2
    }, 'MockJob';

    my $job_instance = Registry::Job::AttendanceCheck->new;
    $job_instance->run($mock_job2);

    # Should still only have 1 reminder notification (no duplicates)
    my $reminder_count = $db->query(
        'SELECT count(*) FROM notifications WHERE user_id = ? AND type = ? AND metadata->>? = ?',
        $data->{teacher}->id, 'attendance_reminder', 'event_id', $event_starting_soon->id
    )->array->[0];

    is($reminder_count, 1, 'No duplicate reminder notifications created');
};

$db_helper->cleanup_test_database;
done_testing;