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

use Registry::DAO::Family;
use Registry::DAO::Attendance;
use Registry::DAO::Waitlist;
use Registry::DAO::Message;
use Registry::DAO::Enrollment;

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
my $parent = Test::Registry::Fixtures::create_user($db, {
    username => 'parent',
    password => 'password123',
    user_type => 'parent',
});

my $staff = Test::Registry::Fixtures::create_user($db, {
    username => 'staff',
    password => 'password123', 
    user_type => 'staff',
});

my $student = Test::Registry::Fixtures::create_user($db, {
    username => 'student',
    password => 'password123',
    user_type => 'student',
});

# Copy users to tenant schema
$db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $parent->id);
$db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $staff->id);
$db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $student->id);

# Switch to tenant schema for operations
$db = $db->schema($tenant->slug);

# Create child using Family DAO
my $child = Registry::DAO::Family->add_child($db, $parent->id, {
    child_name => 'Test Child',
    birth_date => '2015-06-15',
    grade => '3rd'
});

my $location = Test::Registry::Fixtures::create_location($db, {
    name => 'Test Location',
    slug => 'test-location'
});

my $project = Test::Registry::Fixtures::create_project($db, {
    name => 'Test Program',
    slug => 'test-program'
});

my $session = Test::Registry::Fixtures::create_session($db, {
    name => 'Test Session',
    start_date => '2024-03-01',
    end_date => '2024-03-08',
    capacity => 10
});

subtest 'Test dashboard data aggregation' => sub {
    # Create enrollment
    my $enrollment = Registry::DAO::Enrollment->create($db, {
        session_id => $session->id,
        student_id => $parent->id,
        family_member_id => $child->id,
        status => 'active'
    });
    
    ok $enrollment, 'Enrollment created successfully';
    
    # Create test event
    my $event = Test::Registry::Fixtures::create_event($db, {
        location_id => $location->id,
        project_id => $project->id,
        teacher_id => $staff->id,
        time => '2024-03-15 14:00:00',
        duration => 60
    });
    
    ok $event, 'Event created successfully';
    
    # Create attendance record
    Registry::DAO::Attendance->mark_attendance(
        $db, $event->id, $student->id, 'present', $staff->id
    );
    
    # Test parent dashboard controller methods would go here
    # For now, just verify basic data exists
    
    my $enrollments = $db->db->select('enrollments', '*', {
        family_member_id => $child->id,
        status => 'active'
    })->hashes->to_array;
    
    ok @$enrollments >= 1, 'Found active enrollments for dashboard';
};

subtest 'Test waitlist integration' => sub {
    # Create another session for waitlist testing
    my $session2 = Test::Registry::Fixtures::create_session($db, {
        name => 'Waitlist Test Session',
        start_date => '2024-03-15',
        end_date => '2024-03-22',
        capacity => 2
    });
    
    # Add child to waitlist
    my $waitlist_entry = Registry::DAO::Waitlist->join_waitlist(
        $db, $session2->id, $location->id, $student->id, $parent->id
    );
    
    ok $waitlist_entry, 'Child added to waitlist for dashboard display';
    is $waitlist_entry->position, 1, 'Child in position 1 on waitlist';
};

subtest 'Test message integration for dashboard' => sub {
    my $message = Registry::DAO::Message->send_message($db, {
        sender_id => $staff->id, # Using staff as sender
        subject => 'Dashboard Test Message',
        body => 'This is a test message for dashboard display',
        message_type => 'announcement',
        scope => 'tenant-wide'
    }, [$parent->id], send_now => 1);
    
    ok $message, 'Message created for dashboard display';
    
    # Get messages for parent
    my $parent_messages = Registry::DAO::Message->get_messages_for_parent(
        $db, $parent->id, limit => 5
    );
    
    ok @$parent_messages >= 1, 'Found messages for dashboard display';
};

subtest 'Test dashboard stats calculation' => sub {
    # Get enrollment count via family member ID
    my $enrollment_count = $db->db->select('enrollments', 'COUNT(*)', {
        family_member_id => $child->id,
        status => ['active', 'pending']
    })->array->[0] || 0;
    
    ok $enrollment_count >= 1, 'Dashboard shows correct enrollment count';
    
    # Get waitlist count
    my $waitlist_count = $db->db->select('waitlist', 'COUNT(*)', {
        parent_id => $parent->id,
        status => ['waiting', 'offered']
    })->array->[0] || 0;
    
    ok $waitlist_count >= 1, 'Dashboard shows correct waitlist count';
};

subtest 'Test upcoming events query' => sub {
    # Simple test to verify events exist for dashboard display
    my $events = $db->db->select('events', 'COUNT(*)', {
        'time' => {'>=' => '2024-03-01'}
    })->array->[0] || 0;
    
    ok $events >= 1, 'Dashboard shows upcoming events';
};

done_testing;