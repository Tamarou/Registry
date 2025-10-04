use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::Mojo;
use Test::More import => [qw( done_testing is ok diag subtest )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;

# ABOUTME: Test Morgan's session management user journey workflow
# ABOUTME: Validates session scheduling, capacity management, and conflict resolution

my $t    = Test::Mojo->new('Registry');
my $db   = Test::Registry::DB->load;
my $dao  = Registry::DAO->new( db => $db );

# Create test admin user (Morgan persona)
my $morgan = $dao->user->create( $db, {
    username   => 'morgan_sessions',
    password   => 'test_password123',
    email      => 'morgan.session@example.org',
    first_name => 'Morgan',
    last_name  => 'Sessions',
    metadata   => { role => 'admin' }
});

# Create test program for sessions
my $program = $dao->program->create( $db, {
    name     => 'Advanced Mathematics',
    slug     => 'advanced-math',
    metadata => {
        type        => 'academic',
        grade_level => '9-12',
        subject     => 'mathematics'
    }
});

# Create test locations
my $location1 = $dao->location->create( $db, {
    name     => 'Main Campus Room 101',
    slug     => 'main-campus-101',
    capacity => 30,
    metadata => {
        type      => 'classroom',
        equipment => ['projector', 'whiteboard', 'computers']
    }
});

my $location2 = $dao->location->create( $db, {
    name     => 'Science Lab',
    slug     => 'science-lab',
    capacity => 25,
    metadata => {
        type      => 'laboratory',
        equipment => ['lab_benches', 'sinks', 'safety_equipment']
    }
});

# Test: Schedule recurring sessions
subtest 'Schedule recurring sessions' => sub {
    # Login as Morgan
    $t->post_ok('/login', form => {
        username => 'morgan_sessions',
        password => 'test_password123'
    })->status_is(302);

    # Navigate to session management
    $t->get_ok('/admin/sessions')
      ->status_is(200)
      ->text_is('h1', 'Session Management')
      ->element_exists('a[href="/admin/sessions/new"]');

    # Create recurring sessions
    $t->get_ok('/admin/sessions/new')
      ->status_is(200)
      ->text_is('h2', 'Create New Sessions')
      ->element_exists('input[name="recurrence_pattern"]');

    # Submit recurring session configuration
    $t->post_ok('/admin/sessions/new', form => {
        program_id         => $program->id,
        name              => 'Calculus I - Fall 2025',
        recurrence_type   => 'weekly',
        recurrence_days   => 'monday,wednesday,friday',
        start_date        => '2025-09-01',
        end_date          => '2025-12-15',
        start_time        => '09:00',
        end_time          => '10:30',
        location_id       => $location1->id,
        capacity          => 25,
        instructor_id     => undef  # Will assign later
    })->status_is(200)
      ->text_like('.success', qr/45 sessions scheduled successfully/);

    # Verify sessions were created
    my $sessions = $dao->session->find( $db, {
        name => { -like => 'Calculus I - Fall 2025%' }
    });
    ok scalar(@$sessions) > 40, 'Multiple recurring sessions created';
};

# Test: Assign appropriate locations based on needs
subtest 'Assign appropriate locations based on needs' => sub {
    # Create lab-based program
    my $lab_program = $dao->program->create( $db, {
        name     => 'Chemistry Lab Course',
        slug     => 'chemistry-lab',
        metadata => {
            type         => 'science',
            requirements => ['laboratory', 'safety_equipment']
        }
    });

    # Navigate to location assignment
    $t->get_ok('/admin/sessions/location-assignment')
      ->status_is(200)
      ->text_is('h2', 'Location Assignment')
      ->element_exists('select#program-filter');

    # Request location recommendations
    $t->post_ok('/admin/sessions/location-recommendations', form => {
        program_id    => $lab_program->id,
        session_type  => 'laboratory',
        capacity_min  => 20,
        equipment     => 'safety_equipment,sinks'
    })->status_is(200)
      ->json_has('/recommendations/0')
      ->json_is('/recommendations/0/location_id', $location2->id);

    # Assign recommended location
    $t->post_ok('/admin/sessions/assign-location', form => {
        session_id  => 'new-chemistry-session',
        location_id => $location2->id,
        verify_fit  => 1
    })->status_is(200)
      ->text_like('.success', qr/Location assigned/);

    # Verify location requirements match
    $t->get_ok('/admin/sessions/verify-location-fit')
      ->status_is(200)
      ->json_is('/fits_requirements', 1);
};

# Test: Handle session capacity and waitlists
subtest 'Handle session capacity and waitlists' => sub {
    # Get a session
    my $session = $dao->session->find( $db, {
        name => { -like => 'Calculus I - Fall 2025%' }
    })->[0];

    # Navigate to capacity management
    $t->get_ok("/admin/sessions/" . $session->id . "/capacity")
      ->status_is(200)
      ->text_is('h2', 'Capacity Management')
      ->text_like('#current-enrollment', qr/0 \/ 25/);

    # Simulate enrollments to reach capacity
    for my $i (1..25) {
        my $student = $dao->user->create( $db, {
            username => "student_$i",
            password => 'pass',
            email    => "student$i\@example.org",
            metadata => { role => 'student' }
        });

        $dao->enrollment->create( $db, {
            session_id => $session->id,
            user_id    => $student->id,
            status     => 'active'
        });
    }

    # Check capacity status
    $t->get_ok("/admin/sessions/" . $session->id . "/capacity")
      ->status_is(200)
      ->text_like('#current-enrollment', qr/25 \/ 25/)
      ->text_like('.capacity-status', qr/Full/)
      ->element_exists('button#manage-waitlist');

    # Enable waitlist
    $t->post_ok("/admin/sessions/" . $session->id . "/waitlist/enable")
      ->status_is(200)
      ->text_like('.success', qr/Waitlist enabled/);

    # Add student to waitlist
    my $waitlist_student = $dao->user->create( $db, {
        username => 'waitlist_student',
        password => 'pass',
        email    => 'waitlist@example.org',
        metadata => { role => 'student' }
    });

    $t->post_ok("/admin/sessions/" . $session->id . "/waitlist/add", form => {
        user_id  => $waitlist_student->id,
        priority => 1
    })->status_is(200)
      ->text_like('.success', qr/Added to waitlist/);

    # Process waitlist after dropout
    $t->post_ok("/admin/sessions/" . $session->id . "/process-waitlist")
      ->status_is(200)
      ->text_like('#waitlist-status', qr/1 student on waitlist/);

    # Increase capacity
    $t->post_ok("/admin/sessions/" . $session->id . "/capacity/update", form => {
        new_capacity => 30,
        reason       => 'Moved to larger room'
    })->status_is(200)
      ->text_like('.success', qr/Capacity updated to 30/);
};

# Test: Resolve scheduling conflicts
subtest 'Resolve scheduling conflicts' => sub {
    # Create conflicting session attempt
    $t->get_ok('/admin/sessions/new')
      ->status_is(200);

    # Try to schedule overlapping session in same location
    $t->post_ok('/admin/sessions/check-conflicts', json => {
        location_id => $location1->id,
        start_date  => '2025-09-15',
        end_date    => '2025-09-15',
        start_time  => '09:30',
        end_time    => '10:00',
        day         => 'monday'
    })->status_is(200)
      ->json_has('/conflicts')
      ->json_like('/conflicts/0/message', qr/Time conflict/);

    # Get conflict resolution suggestions
    $t->get_ok('/admin/sessions/conflict-resolution')
      ->status_is(200)
      ->text_is('h2', 'Conflict Resolution')
      ->element_exists('#alternative-slots');

    # Accept alternative time slot
    $t->post_ok('/admin/sessions/resolve-conflict', form => {
        original_slot => '2025-09-15 09:30',
        new_slot      => '2025-09-15 11:00',
        location_id   => $location1->id
    })->status_is(200)
      ->text_like('.success', qr/Conflict resolved/);

    # Check instructor conflicts
    my $instructor = $dao->user->create( $db, {
        username => 'instructor_busy',
        password => 'pass',
        email    => 'busy@example.org',
        metadata => { role => 'instructor' }
    });

    # Assign instructor to multiple sessions
    $t->post_ok('/admin/sessions/check-instructor-availability', json => {
        instructor_id => $instructor->id,
        date          => '2025-09-15',
        start_time    => '09:00',
        end_time      => '10:30'
    })->status_is(200)
      ->json_is('/available', 0)
      ->json_like('/reason', qr/Already scheduled/);
};

# Test bulk session operations
subtest 'Bulk session operations' => sub {
    # Navigate to bulk operations
    $t->get_ok('/admin/sessions/bulk-operations')
      ->status_is(200)
      ->text_is('h2', 'Bulk Session Operations')
      ->element_exists('input[type="checkbox"][name="select-all"]');

    # Select multiple sessions for bulk update
    my $sessions = $dao->session->find( $db, {
        name => { -like => 'Calculus I%' }
    });

    my @session_ids = map { $_->id } @$sessions[0..4];

    # Bulk assign instructor
    my $math_instructor = $dao->user->create( $db, {
        username => 'math_instructor',
        password => 'pass',
        email    => 'math@example.org',
        metadata => { role => 'instructor', subject => 'mathematics' }
    });

    $t->post_ok('/admin/sessions/bulk-assign-instructor', json => {
        session_ids   => \@session_ids,
        instructor_id => $math_instructor->id
    })->status_is(200)
      ->json_is('/updated', 5)
      ->json_like('/message', qr/5 sessions updated/);

    # Bulk status change
    $t->post_ok('/admin/sessions/bulk-status', json => {
        session_ids => \@session_ids,
        new_status  => 'published'
    })->status_is(200)
      ->json_is('/updated', 5);
};

# Test session reporting and analytics
subtest 'Session reporting and analytics' => sub {
    # Navigate to session reports
    $t->get_ok('/admin/sessions/reports')
      ->status_is(200)
      ->text_is('h2', 'Session Reports')
      ->element_exists('select#report-type');

    # Generate utilization report
    $t->post_ok('/admin/sessions/reports/utilization', form => {
        date_from => '2025-09-01',
        date_to   => '2025-12-31',
        group_by  => 'location'
    })->status_is(200)
      ->json_has('/utilization/Main Campus Room 101')
      ->json_has('/utilization/Main Campus Room 101/sessions_count')
      ->json_has('/utilization/Main Campus Room 101/average_capacity_used');

    # Generate conflict report
    $t->get_ok('/admin/sessions/reports/conflicts')
      ->status_is(200)
      ->json_has('/scheduling_conflicts')
      ->json_has('/resource_conflicts');
};