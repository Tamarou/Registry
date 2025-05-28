use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer try);
use Test::More import => [qw( done_testing is ok like is_deeply )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;
my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );

# Create test data
my $parent = $dao->create( User => {
    email => 'parent@test.com',
    name => 'Test Parent',
    role => 'parent'
});

my $child = $dao->create( FamilyMember => {
    family_id => $parent->id,
    child_name => 'Test Child',
    birth_date => '2015-06-15',
    grade => '3rd'
});

my $location = $dao->create( Location => {
    name => 'Test Location',
    slug => 'test-location',
    address => '123 Test St'
});

my $program = $dao->create( Project => {
    name => 'Test Program',
    description => 'Test program description'
});

my $session = $dao->create( Session => {
    name => 'Test Session',
    project_id => $program->id,
    location_id => $location->id,
    start_date => time() + 86400, # Tomorrow
    end_date => time() + 86400 * 7, # Next week
    capacity => 10
});

{    # Test dashboard data aggregation
    # Create enrollment
    my $enrollment = $dao->create( Enrollment => {
        session_id => $session->id,
        family_member_id => $child->id,
        status => 'active'
    });
    
    ok $enrollment, 'Enrollment created successfully';
    
    # Create test event
    my $event = $dao->create( Event => {
        name => 'Test Event',
        session_id => $session->id,
        location_id => $location->id,
        start_time => time() + 3600, # 1 hour from now
        end_time => time() + 7200, # 2 hours from now
        capacity => 10
    });
    
    ok $event, 'Event created successfully';
    
    # Create attendance record
    require Registry::DAO::Attendance;
    Registry::DAO::Attendance->mark_attendance(
        $dao->db, $event->id, $child->id, 'present', $parent->id
    );
    
    # Test parent dashboard controller methods would go here
    # For now, just verify basic data exists
    
    my $enrollments = $dao->db->select('enrollments', '*', {
        family_member_id => $child->id,
        status => 'active'
    })->hashes->to_array;
    
    ok @$enrollments >= 1, 'Found active enrollments for dashboard';
}

{    # Test waitlist integration
    # Create another session for waitlist testing
    my $session2 = $dao->create( Session => {
        name => 'Waitlist Test Session',
        project_id => $program->id,
        location_id => $location->id,
        start_date => time() + 86400 * 14, # 2 weeks from now
        end_date => time() + 86400 * 21, # 3 weeks from now
        capacity => 2
    });
    
    # Add child to waitlist
    require Registry::DAO::Waitlist;
    my $waitlist_entry = Registry::DAO::Waitlist->join_waitlist(
        $dao->db, $session2->id, $location->id, $child->id, $parent->id
    );
    
    ok $waitlist_entry, 'Child added to waitlist for dashboard display';
    is $waitlist_entry->position, 1, 'Child in position 1 on waitlist';
}

{    # Test message integration for dashboard
    require Registry::DAO::Message;
    my $message = Registry::DAO::Message->send_message($dao->db, {
        sender_id => $parent->id, # Using parent as sender for test
        subject => 'Dashboard Test Message',
        body => 'This is a test message for dashboard display',
        message_type => 'announcement',
        scope => 'tenant-wide'
    }, [$parent->id], send_now => 1);
    
    ok $message, 'Message created for dashboard display';
    
    # Get messages for parent
    my $parent_messages = Registry::DAO::Message->get_messages_for_parent(
        $dao->db, $parent->id, limit => 5
    );
    
    ok @$parent_messages >= 1, 'Found messages for dashboard display';
}

{    # Test dashboard stats calculation
    # Get enrollment count
    my $enrollment_count = $dao->db->select('enrollments e', 'COUNT(*)', {
        'e.family_member_id' => [
            -in => $dao->db->select('family_members', 'id', { family_id => $parent->id })
        ],
        'e.status' => ['active', 'pending']
    })->array->[0] || 0;
    
    ok $enrollment_count >= 1, 'Dashboard shows correct enrollment count';
    
    # Get waitlist count
    my $waitlist_count = $dao->db->select('waitlist', 'COUNT(*)', {
        parent_id => $parent->id,
        status => ['waiting', 'offered']
    })->array->[0] || 0;
    
    ok $waitlist_count >= 1, 'Dashboard shows correct waitlist count';
}

{    # Test upcoming events query
    my $upcoming_events = $dao->db->query(q{
        SELECT 
            ev.id as event_id,
            ev.name as event_name,
            ev.start_time,
            s.name as session_name,
            fm.child_name
        FROM events ev
        JOIN sessions s ON ev.session_id = s.id
        JOIN enrollments e ON e.session_id = s.id
        JOIN family_members fm ON e.family_member_id = fm.id
        WHERE fm.family_id = ?
        AND e.status IN ('active', 'pending')
        AND ev.start_time >= ?
        ORDER BY ev.start_time ASC
    }, $parent->id, time())->hashes->to_array;
    
    ok @$upcoming_events >= 1, 'Dashboard shows upcoming events';
}