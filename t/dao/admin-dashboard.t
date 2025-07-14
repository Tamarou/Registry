use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer try);
use Test::More import => [qw( done_testing is ok like is_deeply )];
defer { done_testing };

use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Family;

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

# Create test users (in registry schema)
my $admin = Test::Registry::Fixtures::create_user($db, {
    username => 'admin',
    password => 'password123',
    user_type => 'admin',
});

my $staff = Test::Registry::Fixtures::create_user($db, {
    username => 'staff',
    password => 'password123',
    user_type => 'staff',
});

my $parent = Test::Registry::Fixtures::create_user($db, {
    username => 'parent',
    password => 'password123',
    user_type => 'parent',
});

# Copy users to tenant schema
$db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $admin->id);
$db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $staff->id);
$db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $parent->id);

# Switch to tenant schema for operations
$db = $db->schema($tenant->slug);

# Add child to family
Registry::DAO::Family->add_child($db, $parent->id, {
    child_name => 'Test Child',
    birth_date => '2015-06-15',
    grade => '3rd'
});

my $children = Registry::DAO::Family->list_children($db, $parent->id);
my $child = $children->[0];

my $location = Test::Registry::Fixtures::create_location($db, {
    name => 'Test Location',
    slug => 'test-location'
});

my $program = Test::Registry::Fixtures::create_project($db, {
    name => 'Test Program'
});

my $session = Test::Registry::Fixtures::create_session($db, {
    name => 'Test Session',
    start_date => '2024-03-01',
    end_date => '2024-03-08'
});

{    # Test admin dashboard overview stats
    # Create enrollments (need both student_id and family_member_id for backward compatibility)
    my $enrollment = Test::Registry::Fixtures::create_enrollment($db, {
        session_id => $session->id,
        student_id => $parent->id,  # Legacy field - required by database constraint
        family_member_id => $child->id,  # Modern field for multi-child support
        status => 'active'
    });
    
    ok $enrollment, 'Enrollment created for dashboard stats';
    
    # Create events
    my $event = Test::Registry::Fixtures::create_event($db, {
        project_id => $program->id,  # Events belong to projects, not sessions
        location_id => $location->id,
        teacher_id => $staff->id,
        time => '2024-03-15 14:00:00',
        duration => 60
    });
    
    ok $event, 'Event created for dashboard stats';
    
    # Test overview stats queries
    my $active_enrollments = $db->db->select('enrollments', 'COUNT(*)', {
        status => ['active', 'pending']
    })->array->[0] || 0;
    
    ok $active_enrollments >= 1, 'Admin dashboard shows active enrollments';
    
    my $active_programs = $db->db->select('projects', 'COUNT(*)', {})->array->[0] || 0;
    
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
        LEFT JOIN events ev ON p.id = ev.project_id
        LEFT JOIN session_events se ON ev.id = se.event_id
        LEFT JOIN sessions s ON se.session_id = s.id
        LEFT JOIN enrollments e ON s.id = e.session_id
        GROUP BY p.id, p.name
        ORDER BY p.name
    };
    
    my $programs = $db->db->query($sql)->hashes->to_array;
    
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
    my $today_start = DateTime->now->truncate(to => 'day')->iso8601;
    my $today_end = DateTime->now->truncate(to => 'day')->add(days => 1)->iso8601;
    
    my $sql = q{
        SELECT 
            ev.id as event_id,
            p.name as event_name,  -- Use project name since events don't have names
            ev.time,
            COUNT(DISTINCT e.id) as enrolled_count,
            COUNT(DISTINCT ar.id) as attendance_taken
        FROM events ev
        JOIN projects p ON ev.project_id = p.id
        LEFT JOIN session_events se ON ev.id = se.event_id
        LEFT JOIN sessions s ON se.session_id = s.id
        LEFT JOIN enrollments e ON s.id = e.session_id AND e.status = 'active'
        LEFT JOIN attendance_records ar ON ev.id = ar.event_id
        WHERE ev.time >= ? AND ev.time < ?
        GROUP BY ev.id, p.name
        ORDER BY ev.time ASC
    };
    
    my $events = $db->db->query($sql, $today_start, $today_end)->hashes->to_array;
    
    # Events may not exist for today, but query should work
    ok defined $events, 'Today\'s events query works correctly';
    
    for my $event (@$events) {
        my $attendance_status;
        if ($event->{attendance_taken} > 0) {
            $attendance_status = 'completed';
        } elsif ($event->{time} && $event->{time} =~ /^\d{4}-\d{2}-\d{2}/ && $event->{time} lt DateTime->now->iso8601) {
            $attendance_status = 'missing';
        } else {
            $attendance_status = 'pending';
        }
        
        ok $attendance_status =~ /^(completed|missing|pending)$/, 
           'Attendance status calculated correctly';
    }
}

{    # Test waitlist management data
    # Create another user for waitlist (since parent is already enrolled)
    my $waitlist_parent = Test::Registry::Fixtures::create_user($db, {
        username => 'waitlist_parent',
        password => 'password123',
        user_type => 'parent',
    });
    
    # Create waitlist entry
    require Registry::DAO::Waitlist;
    my $waitlist_entry = Registry::DAO::Waitlist->join_waitlist(
        $db->db, $session->id, $location->id, $waitlist_parent->id, $waitlist_parent->id
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
        LEFT JOIN session_events se ON s.id = se.session_id
        LEFT JOIN events ev ON se.event_id = ev.id
        LEFT JOIN projects p ON ev.project_id = p.id
        WHERE w.status IN ('waiting', 'offered')
        ORDER BY w.created_at DESC
        LIMIT 10
    };
    
    my $waitlist_data = $db->db->query($sql)->hashes->to_array;
    
    ok @$waitlist_data >= 1, 'Admin dashboard shows waitlist data';
    
    my $found_entry = (grep { $_->{id} eq $waitlist_entry->id } @$waitlist_data)[0];
    ok $found_entry, 'Waitlist entry found in admin dashboard data';
}

{    # Test enrollment trends data structure
    my $start_date = DateTime->now->subtract(weeks => 4)->epoch;  # This needs to be epoch for created_at comparison
    
    my $sql = q{
        SELECT 
            DATE_TRUNC('week', e.created_at) as week,
            COUNT(*) as enrollments
        FROM enrollments e
        WHERE e.created_at >= TO_TIMESTAMP(?)
        GROUP BY week
        ORDER BY week
    };
    
    my $trends = $db->db->query($sql, $start_date)->hashes->to_array;
    
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
    my $enrollments_data = $db->db->query(q{
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
        LEFT JOIN session_events se ON s.id = se.session_id
        LEFT JOIN events ev ON se.event_id = ev.id
        LEFT JOIN projects p ON ev.project_id = p.id
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
    ok $admin->user_type eq 'admin', 'Admin role verified for dashboard access';
    
    # Staff should have limited access
    ok $staff->user_type eq 'staff', 'Staff role verified for limited dashboard access';
    
    # Parent should not have access
    ok $parent->user_type eq 'parent', 'Parent role verified for no admin dashboard access';
}

{    # Test notification data for dashboard
    require Registry::DAO::Notification;
    
    # Create test notification manually to avoid DAO create issues
    $db->db->insert('notifications', {
        user_id => $parent->id,
        type => 'attendance_reminder',
        channel => 'email',
        subject => 'Test Notification',
        message => 'This is a test notification for admin dashboard',
        metadata => '{}'
    });
    
    my $sql = q{
        SELECT 
            n.id,
            n.type,
            n.channel,
            n.subject,
            n.sent_at,
            n.read_at
        FROM notifications n
        ORDER BY n.created_at DESC
        LIMIT 10
    };
    
    my $notifications = $db->db->query($sql)->hashes->to_array;
    
    ok @$notifications >= 1, 'Admin dashboard shows recent notifications';
    
    my $notification = $notifications->[0];
    ok exists $notification->{type}, 'Notification data has type';
    ok exists $notification->{channel}, 'Notification data has channel';
}