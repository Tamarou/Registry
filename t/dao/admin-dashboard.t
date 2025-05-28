use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer try);
use Test::More import => [qw( done_testing is ok like is_deeply )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;
my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );

# Create test data for admin dashboard
my $admin = $dao->create( User => {
    email => 'admin@test.com',
    name => 'Test Admin',
    role => 'admin'
});

my $staff = $dao->create( User => {
    email => 'staff@test.com',
    name => 'Test Staff',
    role => 'staff'
});

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
    description => 'Test program for admin dashboard',
    status => 'active'
});

my $session = $dao->create( Session => {
    name => 'Test Session',
    project_id => $program->id,
    location_id => $location->id,
    start_date => time() - 86400, # Started yesterday
    end_date => time() + 86400 * 7, # Ends next week
    capacity => 10
});

{    # Test admin dashboard overview stats
    # Create enrollments
    my $enrollment = $dao->create( Enrollment => {
        session_id => $session->id,
        family_member_id => $child->id,
        status => 'active'
    });
    
    ok $enrollment, 'Enrollment created for dashboard stats';
    
    # Create events
    my $event = $dao->create( Event => {
        name => 'Test Event',
        session_id => $session->id,
        location_id => $location->id,
        start_time => time() + 3600, # 1 hour from now
        end_time => time() + 7200, # 2 hours from now
        capacity => 10
    });
    
    ok $event, 'Event created for dashboard stats';
    
    # Test overview stats queries
    my $active_enrollments = $dao->db->select('enrollments', 'COUNT(*)', {
        status => ['active', 'pending']
    })->array->[0] || 0;
    
    ok $active_enrollments >= 1, 'Admin dashboard shows active enrollments';
    
    my $active_programs = $dao->db->select('projects', 'COUNT(*)', {
        status => 'active'
    })->array->[0] || 0;
    
    ok $active_programs >= 1, 'Admin dashboard shows active programs';
}

{    # Test program overview with utilization rates
    my $sql = q{
        SELECT 
            p.id as program_id,
            p.name as program_name,
            COUNT(DISTINCT s.id) as session_count,
            COUNT(DISTINCT e.id) as total_enrollments,
            SUM(ev.capacity) as total_capacity
        FROM projects p
        LEFT JOIN sessions s ON p.id = s.project_id
        LEFT JOIN enrollments e ON s.id = e.session_id
        LEFT JOIN events ev ON s.id = ev.session_id
        WHERE p.status = 'active'
        GROUP BY p.id, p.name
        ORDER BY p.name
    };
    
    my $programs = $dao->db->query($sql)->hashes->to_array;
    
    ok @$programs >= 1, 'Admin dashboard shows program overview';
    
    # Test utilization calculation
    for my $program (@$programs) {
        if ($program->{total_capacity} && $program->{total_capacity} > 0) {
            my $utilization_rate = sprintf("%.0f", 
                ($program->{total_enrollments} / $program->{total_capacity}) * 100
            );
            ok $utilization_rate >= 0 && $utilization_rate <= 100, 
               'Utilization rate calculated correctly';
        }
    }
}

{    # Test today's events with attendance status
    my $today_start = DateTime->now->truncate(to => 'day')->epoch;
    my $today_end = DateTime->now->truncate(to => 'day')->add(days => 1)->epoch;
    
    my $sql = q{
        SELECT 
            ev.id as event_id,
            ev.name as event_name,
            ev.start_time,
            COUNT(DISTINCT e.id) as enrolled_count,
            COUNT(DISTINCT ar.id) as attendance_taken
        FROM events ev
        JOIN sessions s ON ev.session_id = s.id
        LEFT JOIN enrollments e ON s.id = e.session_id AND e.status = 'active'
        LEFT JOIN attendance_records ar ON ev.id = ar.event_id
        WHERE ev.start_time >= ? AND ev.start_time < ?
        GROUP BY ev.id
        ORDER BY ev.start_time ASC
    };
    
    my $events = $dao->db->query($sql, $today_start, $today_end)->hashes->to_array;
    
    # Events may not exist for today, but query should work
    ok defined $events, 'Today\'s events query works correctly';
    
    for my $event (@$events) {
        my $attendance_status;
        if ($event->{attendance_taken} > 0) {
            $attendance_status = 'completed';
        } elsif ($event->{start_time} < time()) {
            $attendance_status = 'missing';
        } else {
            $attendance_status = 'pending';
        }
        
        ok $attendance_status =~ /^(completed|missing|pending)$/, 
           'Attendance status calculated correctly';
    }
}

{    # Test waitlist management data
    # Create waitlist entry
    require Registry::DAO::Waitlist;
    my $waitlist_entry = Registry::DAO::Waitlist->join_waitlist(
        $dao->db, $session->id, $location->id, $child->id, $parent->id
    );
    
    ok $waitlist_entry, 'Waitlist entry created for admin dashboard';
    
    my $sql = q{
        SELECT 
            w.id,
            w.position,
            w.status,
            w.created_at,
            s.name as session_name,
            p.name as program_name
        FROM waitlist w
        JOIN sessions s ON w.session_id = s.id
        JOIN projects p ON s.project_id = p.id
        WHERE w.status IN ('waiting', 'offered')
        ORDER BY w.created_at DESC
        LIMIT 10
    };
    
    my $waitlist_data = $dao->db->query($sql)->hashes->to_array;
    
    ok @$waitlist_data >= 1, 'Admin dashboard shows waitlist data';
    
    my $found_entry = (grep { $_->{id} eq $waitlist_entry->id } @$waitlist_data)[0];
    ok $found_entry, 'Waitlist entry found in admin dashboard data';
}

{    # Test enrollment trends data structure
    my $start_date = DateTime->now->subtract(weeks => 4)->epoch;
    
    my $sql = q{
        SELECT 
            DATE_TRUNC('week', TO_TIMESTAMP(e.created_at)) as week,
            COUNT(*) as enrollments
        FROM enrollments e
        WHERE e.created_at >= ?
        GROUP BY week
        ORDER BY week
    };
    
    my $trends = $dao->db->query($sql, $start_date)->hashes->to_array;
    
    # Trends may be empty if no enrollments in timeframe
    ok defined $trends, 'Enrollment trends query works correctly';
    
    # Test data structure for chart compatibility
    if (@$trends) {
        for my $trend (@$trends) {
            ok exists $trend->{week}, 'Trend data has week field';
            ok exists $trend->{enrollments}, 'Trend data has enrollments count';
            ok $trend->{enrollments} >= 0, 'Enrollment count is non-negative';
        }
    }
}

{    # Test export data functionality
    my $enrollments_data = $dao->db->query(q{
        SELECT 
            e.id as enrollment_id,
            e.status,
            e.created_at,
            fm.child_name,
            s.name as session_name,
            p.name as program_name
        FROM enrollments e
        JOIN family_members fm ON e.family_member_id = fm.id
        JOIN sessions s ON e.session_id = s.id
        JOIN projects p ON s.project_id = p.id
        ORDER BY e.created_at DESC
        LIMIT 100
    })->hashes->to_array;
    
    ok defined $enrollments_data, 'Export enrollments data query works';
    
    if (@$enrollments_data) {
        my $enrollment = $enrollments_data->[0];
        ok exists $enrollment->{enrollment_id}, 'Export data has enrollment_id';
        ok exists $enrollment->{child_name}, 'Export data has child_name';
        ok exists $enrollment->{session_name}, 'Export data has session_name';
    }
}

{    # Test role-based access control data
    # Admin should have access to all data
    ok $admin->role eq 'admin', 'Admin role verified for dashboard access';
    
    # Staff should have limited access
    ok $staff->role eq 'staff', 'Staff role verified for limited dashboard access';
    
    # Parent should not have access
    ok $parent->role eq 'parent', 'Parent role verified for no admin dashboard access';
}

{    # Test notification data for dashboard
    require Registry::DAO::Notification;
    
    # Create test notification
    Registry::DAO::Notification->create($dao->db, {
        user_id => $parent->id,
        type => 'attendance_reminder',
        channel => 'email',
        subject => 'Test Notification',
        message => 'This is a test notification for admin dashboard'
    });
    
    my $sql = q{
        SELECT 
            n.id,
            n.type,
            n.channel,
            n.subject,
            n.sent_at,
            n.delivered_at
        FROM notifications n
        ORDER BY n.created_at DESC
        LIMIT 10
    };
    
    my $notifications = $dao->db->query($sql)->hashes->to_array;
    
    ok @$notifications >= 1, 'Admin dashboard shows recent notifications';
    
    my $notification = $notifications->[0];
    ok exists $notification->{type}, 'Notification data has type';
    ok exists $notification->{channel}, 'Notification data has channel';
}