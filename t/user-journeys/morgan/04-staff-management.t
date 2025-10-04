use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::Mojo;
use Test::More import => [qw( done_testing is ok diag subtest )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;

# ABOUTME: Test Morgan's staff management user journey workflow
# ABOUTME: Validates teacher accounts, assignments, permissions, and monitoring

my $t    = Test::Mojo->new('Registry');
my $db   = Test::Registry::DB->load;
my $dao  = Registry::DAO->new( db => $db );

# Create test admin user (Morgan persona)
my $morgan = $dao->user->create( $db, {
    username   => 'morgan_staff',
    password   => 'test_password123',
    email      => 'morgan.staff@example.org',
    first_name => 'Morgan',
    last_name  => 'StaffManager',
    metadata   => { role => 'admin' }
});

# Test: Create and configure teacher accounts
subtest 'Create and configure teacher accounts' => sub {
    # Login as Morgan
    $t->post_ok('/login', form => {
        username => 'morgan_staff',
        password => 'test_password123'
    })->status_is(302);

    # Navigate to staff management
    $t->get_ok('/admin/staff')
      ->status_is(200)
      ->text_is('h1', 'Staff Management')
      ->element_exists('a[href="/admin/staff/new"]');

    # Create new teacher account
    $t->get_ok('/admin/staff/new')
      ->status_is(200)
      ->text_is('h2', 'Create New Staff Member')
      ->element_exists('form#staff-form');

    # Submit teacher details
    $t->post_ok('/admin/staff/new', form => {
        username        => 'sarah_teacher',
        email           => 'sarah@school.edu',
        first_name      => 'Sarah',
        last_name       => 'Thompson',
        role            => 'teacher',
        department      => 'Mathematics',
        qualifications  => 'MS Mathematics, Teaching Certificate',
        subjects        => 'algebra,geometry,calculus',
        experience_years => 5,
        phone           => '555-0123',
        emergency_contact => 'John Thompson (555-0124)'
    })->status_is(200)
      ->text_like('.success', qr/Staff member created successfully/);

    # Verify teacher was created
    my $teacher = $dao->user->find( $db, { username => 'sarah_teacher' } );
    ok $teacher, 'Teacher account exists';
    is $teacher->metadata->{role}, 'teacher', 'Role is teacher';
    is $teacher->metadata->{department}, 'Mathematics', 'Department is set';

    # Configure teacher profile settings
    $t->get_ok("/admin/staff/" . $teacher->id . "/configure")
      ->status_is(200)
      ->text_is('h2', 'Configure Staff Profile')
      ->element_exists('input[name="availability"]');

    # Set availability and preferences
    $t->post_ok("/admin/staff/" . $teacher->id . "/configure", form => {
        availability_monday    => '08:00-16:00',
        availability_tuesday   => '08:00-16:00',
        availability_wednesday => '08:00-16:00',
        availability_thursday  => '08:00-16:00',
        availability_friday    => '08:00-14:00',
        max_hours_per_week    => 35,
        preferred_age_groups  => '14-16,16-18',
        preferred_class_size  => 20,
        can_substitute        => 1
    })->status_is(200)
      ->text_like('.success', qr/Profile configured/);
};

# Test: Assign teachers to specific sessions
subtest 'Assign teachers to specific sessions' => sub {
    # Create test program and session
    my $program = $dao->program->create( $db, {
        name     => 'Advanced Algebra',
        slug     => 'advanced-algebra',
        metadata => { department => 'Mathematics' }
    });

    my $session = $dao->session->create( $db, {
        name       => 'Algebra Session 1',
        slug       => 'algebra-session-1',
        program_id => $program->id,
        start_date => '2025-09-01',
        end_date   => '2025-12-15',
        capacity   => 25
    });

    my $teacher = $dao->user->find( $db, { username => 'sarah_teacher' } );

    # Navigate to session assignment
    $t->get_ok('/admin/staff/assignments')
      ->status_is(200)
      ->text_is('h2', 'Staff Assignments')
      ->element_exists('select#teacher-select');

    # Assign teacher to session
    $t->post_ok('/admin/staff/assign-session', form => {
        teacher_id => $teacher->id,
        session_id => $session->id,
        role       => 'primary_instructor',
        start_date => '2025-09-01',
        end_date   => '2025-12-15'
    })->status_is(200)
      ->text_like('.success', qr/Teacher assigned to session/);

    # Verify assignment
    my $assignments = $dao->session_teacher->find( $db, {
        teacher_id => $teacher->id,
        session_id => $session->id
    });
    ok $assignments, 'Teacher assigned to session';

    # Check teacher schedule
    $t->get_ok("/admin/staff/" . $teacher->id . "/schedule")
      ->status_is(200)
      ->text_is('h2', 'Sarah Thompson - Schedule')
      ->text_like('.schedule-entry', qr/Algebra Session 1/);

    # Test conflict detection
    my $conflicting_session = $dao->session->create( $db, {
        name       => 'Conflicting Session',
        slug       => 'conflicting-session',
        start_date => '2025-09-01',
        end_date   => '2025-12-15'
    });

    $t->post_ok('/admin/staff/check-assignment-conflict', json => {
        teacher_id => $teacher->id,
        session_id => $conflicting_session->id,
        time_slot  => 'monday_08:00-10:00'
    })->status_is(200)
      ->json_is('/has_conflict', 1)
      ->json_like('/conflict_reason', qr/Already assigned/);
};

# Test: Set up role-based permissions
subtest 'Set up role-based permissions' => sub {
    # Navigate to role management
    $t->get_ok('/admin/staff/roles')
      ->status_is(200)
      ->text_is('h2', 'Role Management')
      ->element_exists('button#create-role');

    # Create custom role
    $t->post_ok('/admin/staff/roles/create', form => {
        role_name    => 'lead_instructor',
        display_name => 'Lead Instructor',
        description  => 'Senior teaching staff with additional privileges'
    })->status_is(200)
      ->text_like('.success', qr/Role created/);

    # Define permissions for role
    $t->post_ok('/admin/staff/roles/lead_instructor/permissions', json => {
        permissions => [
            'view_all_sessions',
            'edit_own_sessions',
            'manage_session_materials',
            'view_student_records',
            'submit_grades',
            'create_assessments',
            'manage_substitutes',
            'approve_lesson_plans'
        ]
    })->status_is(200)
      ->json_is('/updated', 8)
      ->json_like('/message', qr/Permissions updated/);

    # Assign role to teacher
    my $teacher = $dao->user->find( $db, { username => 'sarah_teacher' } );

    $t->post_ok("/admin/staff/" . $teacher->id . "/roles", form => {
        role       => 'lead_instructor',
        effective_date => '2025-09-01',
        department => 'Mathematics'
    })->status_is(200)
      ->text_like('.success', qr/Role assigned/);

    # Create restricted role
    $t->post_ok('/admin/staff/roles/create', form => {
        role_name    => 'assistant_teacher',
        display_name => 'Assistant Teacher',
        description  => 'Support staff with limited privileges'
    })->status_is(200);

    $t->post_ok('/admin/staff/roles/assistant_teacher/permissions', json => {
        permissions => [
            'view_own_sessions',
            'view_session_materials',
            'mark_attendance'
        ]
    })->status_is(200);

    # Test permission inheritance
    $t->get_ok('/admin/staff/roles/hierarchy')
      ->status_is(200)
      ->json_has('/roles/admin')
      ->json_has('/roles/lead_instructor')
      ->json_has('/roles/teacher')
      ->json_has('/roles/assistant_teacher');
};

# Test: Monitor and report on teacher activities
subtest 'Monitor and report on teacher activities' => sub {
    my $teacher = $dao->user->find( $db, { username => 'sarah_teacher' } );

    # Navigate to activity monitoring
    $t->get_ok('/admin/staff/monitoring')
      ->status_is(200)
      ->text_is('h2', 'Staff Activity Monitoring')
      ->element_exists('input#date-range');

    # View teacher activity log
    $t->get_ok("/admin/staff/" . $teacher->id . "/activity")
      ->status_is(200)
      ->text_is('h2', 'Activity Log: Sarah Thompson')
      ->element_exists('.activity-timeline');

    # Generate attendance report
    $t->post_ok('/admin/staff/reports/attendance', form => {
        teacher_id => $teacher->id,
        date_from  => '2025-09-01',
        date_to    => '2025-09-30'
    })->status_is(200)
      ->json_has('/attendance_rate')
      ->json_has('/sessions_taught')
      ->json_has('/absences');

    # Performance metrics
    $t->get_ok("/admin/staff/" . $teacher->id . "/metrics")
      ->status_is(200)
      ->text_is('h2', 'Performance Metrics')
      ->text_like('#student-feedback-score', qr/\d+\.\d+\/5/)
      ->text_like('#completion-rate', qr/\d+%/)
      ->text_like('#punctuality-score', qr/\d+%/);

    # Generate comprehensive staff report
    $t->post_ok('/admin/staff/reports/comprehensive', form => {
        report_type => 'monthly',
        month       => '2025-09',
        include     => 'attendance,performance,feedback,workload'
    })->status_is(200)
      ->json_has('/staff_summary')
      ->json_has('/department_breakdown')
      ->json_has('/workload_distribution');

    # Alert configuration for monitoring
    $t->post_ok("/admin/staff/" . $teacher->id . "/alerts", form => {
        alert_absence        => 1,
        alert_low_performance => 1,
        alert_overload       => 1,
        max_weekly_hours     => 40
    })->status_is(200)
      ->text_like('.success', qr/Alerts configured/);
};

# Test staff onboarding workflow
subtest 'Staff onboarding workflow' => sub {
    # Create new teacher for onboarding
    my $new_teacher = $dao->user->create( $db, {
        username   => 'new_teacher',
        password   => 'temp_pass123',
        email      => 'newteacher@school.edu',
        first_name => 'Jane',
        last_name  => 'Doe',
        metadata   => {
            role   => 'teacher',
            status => 'onboarding'
        }
    });

    # Navigate to onboarding
    $t->get_ok('/admin/staff/onboarding')
      ->status_is(200)
      ->text_is('h2', 'Staff Onboarding')
      ->text_like('.onboarding-list', qr/Jane Doe/);

    # Start onboarding process
    $t->post_ok("/admin/staff/" . $new_teacher->id . "/onboarding/start")
      ->status_is(200)
      ->json_has('/checklist')
      ->json_is('/checklist/0/task', 'Complete profile information')
      ->json_is('/checklist/1/task', 'Submit credentials')
      ->json_is('/checklist/2/task', 'Complete training modules');

    # Mark onboarding tasks complete
    $t->post_ok("/admin/staff/" . $new_teacher->id . "/onboarding/complete-task", form => {
        task_id => 'profile_complete',
        notes   => 'All information verified'
    })->status_is(200);

    # Complete onboarding
    $t->post_ok("/admin/staff/" . $new_teacher->id . "/onboarding/complete")
      ->status_is(200)
      ->text_like('.success', qr/Onboarding completed/);

    # Verify status change
    my $onboarded = $dao->user->find( $db, { id => $new_teacher->id } );
    is $onboarded->metadata->{status}, 'active', 'Teacher status is active';
};

# Test substitute teacher management
subtest 'Substitute teacher management' => sub {
    # Create substitute teacher
    my $substitute = $dao->user->create( $db, {
        username   => 'sub_teacher',
        password   => 'pass123',
        email      => 'substitute@school.edu',
        first_name => 'Mark',
        last_name  => 'SubTeacher',
        metadata   => {
            role     => 'substitute',
            subjects => ['mathematics', 'science'],
            availability => 'on_call'
        }
    });

    # Navigate to substitute management
    $t->get_ok('/admin/staff/substitutes')
      ->status_is(200)
      ->text_is('h2', 'Substitute Teachers')
      ->element_exists('button#request-substitute');

    # Request substitute for absence
    my $teacher = $dao->user->find( $db, { username => 'sarah_teacher' } );
    my $session = $dao->session->find( $db, { name => 'Algebra Session 1' } );

    $t->post_ok('/admin/staff/request-substitute', form => {
        absent_teacher_id => $teacher->id,
        session_id        => $session->id,
        date              => '2025-09-15',
        reason            => 'Medical appointment',
        requirements      => 'Mathematics qualified, Algebra experience'
    })->status_is(200)
      ->text_like('.success', qr/Substitute request created/);

    # Assign substitute
    $t->post_ok('/admin/staff/assign-substitute', form => {
        request_id    => 1,
        substitute_id => $substitute->id,
        confirmed     => 1
    })->status_is(200)
      ->text_like('.success', qr/Mark SubTeacher assigned as substitute/);

    # Track substitute history
    $t->get_ok("/admin/staff/" . $substitute->id . "/substitute-history")
      ->status_is(200)
      ->text_is('h2', 'Substitute Assignment History')
      ->text_like('.assignment-entry', qr/Algebra Session 1.*2025-09-15/);
};