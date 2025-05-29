use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is ok subtest like )];
defer { done_testing };

use Test::Mojo;
use Registry;
use Registry::DAO;
use Test::Registry::DB;

my $app = Registry->new;
my $t = Test::Mojo->new($app);
my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );

subtest "Teacher Dashboard Controller Exists" => sub {
    ok(Registry::Controller::TeacherDashboard->can('attendance'), 'TeacherDashboard has attendance method');
    ok(Registry::Controller::TeacherDashboard->can('dashboard'), 'TeacherDashboard has dashboard method');
    ok(Registry::Controller::TeacherDashboard->can('mark_attendance'), 'TeacherDashboard has mark_attendance method');
    ok(Registry::Controller::TeacherDashboard->can('auth_check'), 'TeacherDashboard has auth_check method');
};

subtest "Teacher Routes Configuration" => sub {
    # Test that routes are configured (they will redirect due to auth)
    $t->get_ok('/teacher/')
      ->status_is(302) # Redirects to signup due to auth_check
      ->header_like(Location => qr{/teacher-signup});
    
    $t->get_ok('/teacher/attendance/test-event-123')
      ->status_is(302) # Redirects to signup due to auth_check  
      ->header_like(Location => qr{/teacher-signup});
};

subtest "Event DAO Methods" => sub {
    # Test that the new DAO methods exist
    ok(Registry::DAO::Event->can('get_teacher_events_for_date'), 'Event DAO has get_teacher_events_for_date method');
    ok(Registry::DAO::Event->can('get_teacher_upcoming_events'), 'Event DAO has get_teacher_upcoming_events method');
};

subtest "Enrollment DAO Methods" => sub {
    # Test that the new DAO methods exist
    ok(Registry::DAO::Enrollment->can('get_students_for_event'), 'Enrollment DAO has get_students_for_event method');
};

subtest "Template Files Exist" => sub {
    ok(-f 'templates/layouts/teacher.html.ep', 'Teacher layout template exists');
    ok(-f 'templates/teacher/attendance.html.ep', 'Teacher attendance template exists');
    ok(-f 'templates/teacher/dashboard.html.ep', 'Teacher dashboard template exists');
};

subtest "Mobile Responsive Templates" => sub {
    # Check that templates contain mobile-responsive meta tags and CSS
    my $layout_content = do {
        local $/;
        open my $fh, '<', 'templates/layouts/teacher.html.ep' or die $!;
        <$fh>;
    };
    
    like($layout_content, qr/viewport.*width=device-width/, 'Teacher layout has mobile viewport meta tag');
    like($layout_content, qr/font-size:\s*16px/, 'Teacher layout has touch-friendly button sizes');
    
    # Check that Web Components have mobile-responsive styles
    my $js_content = do {
        local $/;
        open my $fh, '<', 'public/js/attendance-components.js' or die $!;
        <$fh>;
    };
    
    like($js_content, qr/attendance-btn/, 'Web components contain attendance button styles');
    like($js_content, qr/min-width:\s*80px/, 'Web components have minimum touch target size');
};

subtest "Web Components Functionality" => sub {
    my $attendance_content = do {
        local $/;
        open my $fh, '<', 'templates/teacher/attendance.html.ep' or die $!;
        <$fh>;
    };
    
    like($attendance_content, qr/student-attendance-row/, 'Template uses student-attendance-row component');
    like($attendance_content, qr/attendance-form/, 'Template uses attendance-form component'); 
    like($attendance_content, qr/attendance-components\.js/, 'Template loads web components script');
    like($attendance_content, qr/customElements\.whenDefined/, 'Template waits for components to be defined');
    
    # Check that the JavaScript file exists
    ok(-f 'public/js/attendance-components.js', 'Web components JavaScript file exists');
    
    # Check components content
    my $js_content = do {
        local $/;
        open my $fh, '<', 'public/js/attendance-components.js' or die $!;
        <$fh>;
    };
    
    like($js_content, qr/customElements\.define/, 'JavaScript defines custom elements');
    like($js_content, qr/StudentAttendanceRow/, 'JavaScript contains StudentAttendanceRow class');
    like($js_content, qr/AttendanceForm/, 'JavaScript contains AttendanceForm class');
    like($js_content, qr/shadowRoot/, 'Components use Shadow DOM');
};