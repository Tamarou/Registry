#!/usr/bin/env perl

use 5.40.2;
use experimental qw( try );

# Set up test email transport BEFORE loading any modules that might use Email::Sender
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test'; }

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::Job::AttendanceCheck;
use Registry::DAO::User;
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Session;
use Registry::DAO::Enrollment;
use Registry::DAO::Attendance;
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

subtest 'End-to-end attendance notification workflow' => sub {
    # Clean up any existing data
    $db->delete('notifications', {});
    $db->delete('attendance_records', {});
    
    # Create test users
    my $teacher1 = Registry::DAO::User->create($db, {
        username => 'teacher1',
        passhash => 'fake_hash'
    });
    
    $db->insert('user_profiles', {
        user_id => $teacher1->id,
        email => 'teacher1@example.com',
        name => 'Ms. Smith'
    });

    my $teacher2 = Registry::DAO::User->create($db, {
        username => 'teacher2',
        passhash => 'fake_hash'
    });
    
    $db->insert('user_profiles', {
        user_id => $teacher2->id,
        email => 'teacher2@example.com',
        name => 'Mr. Johnson'
    });

    my $student1 = Registry::DAO::User->create($db, {
        username => 'student1',
        passhash => 'fake_hash'
    });

    my $student2 = Registry::DAO::User->create($db, {
        username => 'student2',
        passhash => 'fake_hash'
    });

    # Set up notification preferences
    # Teacher1: wants all notifications via email and in-app
    Registry::DAO::UserPreference->update_notification_preferences($db, $teacher1->id, {
        attendance_missing => { email => 1, in_app => 1 },
        attendance_reminder => { email => 1, in_app => 1 }
    });

    # Teacher2: only wants in-app notifications
    Registry::DAO::UserPreference->update_notification_preferences($db, $teacher2->id, {
        attendance_missing => { email => 0, in_app => 1 },
        attendance_reminder => { email => 0, in_app => 1 }
    });

    # Create locations and projects
    my $location1 = Registry::DAO::Location->create($db, {
        name => 'Main Classroom',
        slug => 'main-classroom',
        address_info => { building => 'A', room => '101' }
    });

    my $location2 = Registry::DAO::Location->create($db, {
        name => 'Art Studio',
        slug => 'art-studio',
        address_info => { building => 'B', room => '202' }
    });

    my $project1 = Registry::DAO::Project->create($db, {
        name => 'Math Tutoring',
        slug => 'math-tutoring'
    });

    my $project2 = Registry::DAO::Project->create($db, {
        name => 'Art Workshop',
        slug => 'art-workshop'
    });

    # Create sessions and enrollments
    my $session1 = Registry::DAO::Session->create($db, {
        name => 'Math Session A',
        slug => 'math-session-a'
    });

    my $session2 = Registry::DAO::Session->create($db, {
        name => 'Art Session B',
        slug => 'art-session-b'
    });

    # Enroll students
    my $enrollment1 = Registry::DAO::Enrollment->create($db, {
        student_id => $student1->id,
        session_id => $session1->id,
        status => 'active'
    });

    my $enrollment2 = Registry::DAO::Enrollment->create($db, {
        student_id => $student2->id,
        session_id => $session2->id,
        status => 'active'
    });

    # Scenario 1: Event that started 10 minutes ago, no attendance taken
    my $past_time = DateTime->now->subtract(minutes => 10);
    my $event_missing_attendance = Registry::DAO::Event->create($db, {
        location_id => $location1->id,
        project_id => $project1->id,
        teacher_id => $teacher1->id,
        start_time => $past_time,
        end_time => DateTime->now->add(minutes => 50),
        metadata => {
            title => 'Math Tutoring - Morning Session'
        }
    });

    # Link session to event
    $db->insert('session_events', {
        session_id => $session1->id,
        event_id => $event_missing_attendance->id
    });

    # Scenario 2: Event starting in 3 minutes (should get reminder)
    my $soon_time = DateTime->now->add(minutes => 3);
    my $event_starting_soon = Registry::DAO::Event->create($db, {
        location_id => $location2->id,
        project_id => $project2->id,
        teacher_id => $teacher2->id,
        start_time => $soon_time,
        end_time => DateTime->now->add(minutes => 63),
        metadata => {
            title => 'Art Workshop - Afternoon Session'
        }
    });

    # Link session to event
    $db->insert('session_events', {
        session_id => $session2->id,
        event_id => $event_starting_soon->id
    });

    # Scenario 3: Event that started 5 minutes ago but already has attendance
    my $past_time_with_attendance = DateTime->now->subtract(minutes => 5);
    my $event_with_attendance = Registry::DAO::Event->create($db, {
        location_id => $location1->id,
        project_id => $project1->id,
        teacher_id => $teacher1->id,
        start_time => $past_time_with_attendance,
        end_time => DateTime->now->add(minutes => 55),
        metadata => {
            title => 'Math Tutoring - Completed Session'
        }
    });

    # Add attendance for this event
    Registry::DAO::Attendance->mark_attendance(
        $db, $event_with_attendance->id, $student1->id, 'present', $teacher1->id
    );

    # Run the attendance check job
    my $mock_logger = bless {}, 'MockLogger';
    my $mock_app = bless {
        log => $mock_logger,
        dao => sub { $dao }
    }, 'MockApp';
    my $mock_job = bless {
        app => $mock_app
    }, 'MockJob';
    
    # Mock logger and app classes
    {
        package MockLogger;
        sub info { shift; say "INFO: @_" if $ENV{TEST_VERBOSE} }
        sub debug { shift; say "DEBUG: @_" if $ENV{TEST_VERBOSE} }
        sub error { shift; say "ERROR: @_" if $ENV{TEST_VERBOSE} }
    }
    
    {
        package MockApp;
        sub dao { $dao }
        sub log { shift->{log} }
    }
    
    {
        package MockJob;
        sub app { shift->{app} }
    }

    my $job_instance = Registry::Job::AttendanceCheck->new;
    $job_instance->check_tenant_attendance($mock_job, $db, 'public');

    # Verify email notifications were created and sent successfully
    my $email_notifications = $db->select('notifications', 'count(*)', {
        channel => 'email',
        'sent_at' => { '!=' => undef }
    })->array->[0];
    
    is($email_notifications, 1, 'One email notification was created and marked as sent');
    
    # Verify no email notifications failed
    my $failed_emails = $db->select('notifications', 'count(*)', {
        channel => 'email',
        'failed_at' => { '!=' => undef }
    })->array->[0];
    
    is($failed_emails, 0, 'No email notifications failed');

    # Verify notifications were created correctly
    my $all_notifications = $db->select('notifications', '*', {}, { -asc => ['user_id', 'type', 'channel'] })->hashes->to_array;

    # Should have:
    # - 2 notifications for teacher1 (missing attendance: email + in_app)
    # - 1 notification for teacher2 (reminder: in_app only)
    is(scalar @$all_notifications, 3, 'Created expected number of notifications');

    # Check teacher1's notifications (missing attendance)
    my @teacher1_notifications = grep { $_->{user_id} eq $teacher1->id } @$all_notifications;
    is(scalar @teacher1_notifications, 2, 'Teacher1 received 2 notifications');

    my ($teacher1_email) = grep { $_->{channel} eq 'email' } @teacher1_notifications;
    my ($teacher1_in_app) = grep { $_->{channel} eq 'in_app' } @teacher1_notifications;

    ok($teacher1_email, 'Teacher1 received email notification');
    ok($teacher1_in_app, 'Teacher1 received in-app notification');

    is($teacher1_email->{type}, 'attendance_missing', 'Email notification has correct type');
    is($teacher1_in_app->{type}, 'attendance_missing', 'In-app notification has correct type');

    like($teacher1_email->{subject}, qr/Attendance Missing/, 'Email subject contains "Attendance Missing"');
    like($teacher1_email->{message}, qr/Math Tutoring - Morning Session/, 'Email message contains event title');

    # Check that in-app notification is marked as sent
    ok(defined $teacher1_in_app->{sent_at}, 'In-app notification marked as sent');

    # Check teacher2's notification (reminder)
    my @teacher2_notifications = grep { $_->{user_id} eq $teacher2->id } @$all_notifications;
    is(scalar @teacher2_notifications, 1, 'Teacher2 received 1 notification');

    my $teacher2_notification = $teacher2_notifications[0];
    is($teacher2_notification->{channel}, 'in_app', 'Teacher2 received only in-app notification');
    is($teacher2_notification->{type}, 'attendance_reminder', 'Notification has correct type');
    like($teacher2_notification->{subject}, qr/Attendance Reminder/, 'Subject contains "Attendance Reminder"');
    like($teacher2_notification->{message}, qr/Art Workshop - Afternoon Session/, 'Message contains event title');

    # Test notification methods
    my $notification_obj = Registry::DAO::Notification->new(%$teacher1_in_app);
    ok($notification_obj->is_sent, 'Notification correctly identified as sent');
    ok($notification_obj->is_attendance_notification, 'Notification correctly identified as attendance notification');
    
    done_testing();
};

subtest 'Notification preferences respected' => sub {
    # Clean up
    $db->delete('notifications', {});
    
    # Create a teacher who doesn't want any notifications
    my $teacher_no_notif = Registry::DAO::User->create($db, {
        username => 'teacher_no_notif',
        passhash => 'fake_hash'
    });
    
    $db->insert('user_profiles', {
        user_id => $teacher_no_notif->id,
        email => 'no_notif@example.com',
        name => 'Ms. Quiet'
    });

    # Set preferences to disable all notifications
    Registry::DAO::UserPreference->update_notification_preferences($db, $teacher_no_notif->id, {
        attendance_missing => { email => 0, in_app => 0 },
        attendance_reminder => { email => 0, in_app => 0 }
    });

    # Create student and infrastructure
    my $student = Registry::DAO::User->create($db, {
        username => 'student_quiet',
        passhash => 'fake_hash'
    });

    my $location = Registry::DAO::Location->create($db, {
        name => 'Quiet Classroom',
        slug => 'quiet-classroom',
        address_info => {}
    });

    my $project = Registry::DAO::Project->create($db, {
        name => 'Silent Study',
        slug => 'silent-study'
    });

    my $session = Registry::DAO::Session->create($db, {
        name => 'Quiet Session',
        slug => 'quiet-session'
    });

    my $enrollment = Registry::DAO::Enrollment->create($db, {
        student_id => $student->id,
        session_id => $session->id,
        status => 'active'
    });

    # Create event missing attendance
    my $past_time = DateTime->now->subtract(minutes => 10);
    my $event = Registry::DAO::Event->create($db, {
        location_id => $location->id,
        project_id => $project->id,
        teacher_id => $teacher_no_notif->id,
        start_time => $past_time,
        end_time => DateTime->now->add(minutes => 50),
        metadata => {
            title => 'Silent Study Session'
        }
    });

    $db->insert('session_events', {
        session_id => $session->id,
        event_id => $event->id
    });

    # Run job
    my $mock_logger2 = bless {}, 'MockLogger';
    my $mock_app2 = bless {
        log => $mock_logger2,
        dao => sub { $dao }
    }, 'MockApp';
    my $mock_job = bless {
        app => $mock_app2
    }, 'MockJob';

    my $job_instance = Registry::Job::AttendanceCheck->new;
    $job_instance->check_tenant_attendance($mock_job, $db, 'public');

    # Verify no notifications were created
    my $notification_count = $db->select('notifications', 'count(*)', {
        user_id => $teacher_no_notif->id
    })->array->[0];

    is($notification_count, 0, 'No notifications created when teacher has disabled them');
    
    done_testing();
};

subtest 'Duplicate prevention' => sub {
    # Clean up
    $db->delete('notifications', {});
    
    # Create teacher and basic infrastructure 
    my $teacher = Registry::DAO::User->create($db, {
        username => 'teacher_dup_test',
        passhash => 'fake_hash'
    });
    
    $db->insert('user_profiles', {
        user_id => $teacher->id,
        email => 'dup_test@example.com',
        name => 'Ms. DupTest'
    });

    my $student = Registry::DAO::User->create($db, {
        username => 'student_dup_test',
        passhash => 'fake_hash'
    });

    my $location = Registry::DAO::Location->create($db, {
        name => 'Dup Test Classroom',
        slug => 'dup-test-classroom',
        address_info => {}
    });

    my $project = Registry::DAO::Project->create($db, {
        name => 'Dup Test Project',
        slug => 'dup-test-project'
    });

    my $session = Registry::DAO::Session->create($db, {
        name => 'Dup Test Session',
        slug => 'dup-test-session'
    });

    my $enrollment = Registry::DAO::Enrollment->create($db, {
        student_id => $student->id,
        session_id => $session->id,
        status => 'active'
    });

    # Create event starting soon (for reminder test)
    my $soon_time = DateTime->now->add(minutes => 3);
    my $event = Registry::DAO::Event->create($db, {
        location_id => $location->id,
        project_id => $project->id,
        teacher_id => $teacher->id,
        start_time => $soon_time,
        end_time => DateTime->now->add(minutes => 63),
        metadata => {
            title => 'Dup Test Event'
        }
    });

    $db->insert('session_events', {
        session_id => $session->id,
        event_id => $event->id
    });

    # Manually create a reminder notification first
    Registry::DAO::Notification->create($db, {
        user_id => $teacher->id,
        type => 'attendance_reminder',
        channel => 'email',
        subject => 'Manual Reminder',
        message => 'Manually created reminder',
        metadata => { event_id => $event->id }
    });

    # Run job
    my $mock_logger3 = bless {}, 'MockLogger';
    my $mock_app3 = bless {
        log => $mock_logger3,
        dao => sub { $dao }
    }, 'MockApp';
    my $mock_job = bless {
        app => $mock_app3
    }, 'MockJob';

    my $job_instance = Registry::Job::AttendanceCheck->new;
    $job_instance->check_tenant_attendance($mock_job, $db, 'public');

    # Should only have 1 reminder notification (no duplicates)
    my $reminder_count = $db->query(
        'SELECT count(*) FROM notifications WHERE user_id = ? AND type = ? AND metadata->>? = ?',
        $teacher->id, 'attendance_reminder', 'event_id', $event->id
    )->array->[0];

    is($reminder_count, 1, 'Duplicate reminder notifications prevented');
    
    done_testing();
};

$db_helper->cleanup_test_database;
done_testing;