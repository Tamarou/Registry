#!/usr/bin/env perl
# ABOUTME: Amara (teacher) journey: view schedule, take attendance, mark students.
# ABOUTME: Tests the teacher dashboard and attendance marking workflow at HTTP layer.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw(diag done_testing is is_deeply ok like subtest)];
defer { done_testing };

use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::Helpers qw(authenticate_as import_all_workflows);
use Registry::DAO;
use Registry::DAO::User;
use Registry::DAO::Family;
use Mojo::JSON qw(decode_json encode_json);

my $test_db = Test::Registry::DB->new;
my $dao = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

import_all_workflows($dao);

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

# --- Test Data Setup ---

my $amara = $dao->create(User => {
    username  => 'amara_teacher',
    name      => 'Amara Chen',
    email     => 'amara@tinyartempire.com',
    user_type => 'staff',
});

my $location = $dao->create(Location => {
    name         => 'Art Studio',
    slug         => 'art-studio',
    address_info => { street => '200 Creative Way', city => 'Orlando', state => 'FL' },
    metadata     => {},
});

my $program = $dao->create(Project => { status => 'published',
    name              => 'Painting Basics',
    program_type_slug => 'afterschool',
    metadata          => {},
});

# Create a session happening today so it appears on the teacher dashboard
my $today = DateTime->now->ymd;
my $session = $dao->create(Session => {
    name       => 'Today\'s Painting Class',
    start_date => $today,
    end_date   => $today,
    status     => 'published',
    capacity   => 12,
    metadata   => {},
});

my $now_time = DateTime->now->strftime('%Y-%m-%d %H:%M:%S');
my $event = $dao->create(Event => {
    time        => $now_time,
    duration    => 120,
    location_id => $location->id,
    project_id  => $program->id,
    teacher_id  => $amara->id,
    capacity    => 12,
    metadata    => {},
});
$session->add_events($dao->db, $event->id);

# Enroll some students
my $parent = $dao->create(User => {
    username  => 'att_parent',
    name      => 'Parent One',
    email     => 'parent1@example.com',
    user_type => 'parent',
});

my $child1 = Registry::DAO::Family->add_child($dao->db, $parent->id, {
    child_name        => 'Student Alpha',
    birth_date        => '2017-03-15',
    grade             => '3',
    medical_info      => {},
    emergency_contact => { name => 'Parent One', phone => '555-0001' },
});

my $child2 = Registry::DAO::Family->add_child($dao->db, $parent->id, {
    child_name        => 'Student Beta',
    birth_date        => '2018-07-22',
    grade             => '2',
    medical_info      => {},
    emergency_contact => { name => 'Parent One', phone => '555-0001' },
});

# Each enrollment needs a unique student_id; use the family_member_id
# as the student_id to satisfy the unique constraint.
for my $child ($child1, $child2) {
    $dao->db->insert('enrollments', {
        session_id       => $session->id,
        student_id       => $child->id,
        family_member_id => $child->id,
        parent_id        => $parent->id,
        status           => 'active',
        metadata         => '{}',
    });
}

# Authenticate as Amara
authenticate_as($t, $amara);

# === Amara's Teaching Journey ===

subtest 'Amara can access teacher dashboard' => sub {
    $t->get_ok('/teacher/')
      ->status_is(200)
      ->content_like(qr/Teacher Dashboard/, 'Dashboard title rendered')
      ->element_exists('nav.dashboard-nav', 'Navigation bar present');
};

subtest 'Amara sees navigation with appropriate links' => sub {
    $t->get_ok('/teacher/')
      ->status_is(200)
      ->element_exists('nav.dashboard-nav a[href="/teacher/"]', 'Attendance link in nav')
      ->element_exists('nav.dashboard-nav a[href="/admin/dashboard"]', 'Admin dashboard link in nav');
};

subtest 'Amara can view attendance page for an event' => sub {
    $t->get_ok("/teacher/attendance/${\$event->id}")
      ->status_is(200)
      ->content_like(qr/Class Session|Attendance/, 'Attendance page rendered')
      ->element_exists('attendance-form', 'Attendance form web component present');
};

# Marking attendance is the thing a teacher does every session. The previous
# version of this subtest accepted a 200, a 400 or a 500 and passed on all
# three, so a teacher's attendance could have been entirely broken and this
# journey stayed green. It also never looked at whether anything was recorded.
sub mark_attendance_over_http ( $data ) {
    $t->get_ok('/teacher/')->status_is(200);
    my $csrf = $t->tx->res->dom->at('meta[name="csrf-token"]');

    # The UA directly, because this endpoint takes JSON rather than a form.
    my $tx = $t->ua->post( "/teacher/attendance/${\$event->id}" => {
        'Content-Type' => 'application/json',
        'X-CSRF-Token' => $csrf ? $csrf->attr('content') : '',
    } => Mojo::JSON::encode_json($data) );
    $t->tx($tx);

    return ( $t->tx->res->code, $t->tx->res->json // {} );
}

sub recorded_status ( $student_id ) {
    my $row = $dao->db->select( 'attendance_records', ['status'],
        { event_id => $event->id, student_id => $student_id } )->hash;
    return $row ? $row->{status} : undef;
}

subtest 'Amara can mark student attendance' => sub {
    my ( $status, $body ) = mark_attendance_over_http( {
        $child1->id => 'present',
        $child2->id => 'absent',
    } );

    is $status, 200, 'the request succeeds'
        or diag 'response: ' . ( $body->{error} // $body->{details} // 'none' );
    ok $body->{success}, 'and reports success';

    # The point of the request. A 200 that recorded nothing is the failure
    # this journey exists to catch.
    is recorded_status( $child1->id ), 'present', 'the present child is recorded';
    is recorded_status( $child2->id ), 'absent',  'the absent child is recorded';
};

# A teacher correcting a mistake mid-session, which is the common case: the
# same student marked twice must end with one row, not two.
subtest 'marking a student again corrects the record rather than duplicating it' => sub {
    my ( $status, $body ) = mark_attendance_over_http( { $child2->id => 'present' } );

    is $status, 200, 'the correction succeeds';
    is recorded_status( $child2->id ), 'present', 'and the status is updated';

    my $rows = $dao->db->select( 'attendance_records', 'COUNT(*)',
        { event_id => $event->id, student_id => $child2->id } )->array->[0];
    is $rows, 1, 'leaving one row for this student on this event';
};

# The controller skips any status it does not recognise. Saying it marked them
# anyway tells a teacher the register is complete when it is not.
subtest 'a status the controller refuses is not counted as marked' => sub {
    my ( $status, $body ) = mark_attendance_over_http( {
        $child1->id => 'present',
        $child2->id => 'maybe',
    } );

    is $status, 200, 'the recognised part still succeeds';
    is recorded_status( $child1->id ), 'present', 'the valid status is recorded';
    is $body->{total_marked}, 1, 'and only what was marked is reported';
};

subtest 'a payload that is not attendance data is refused' => sub {
    my ( $status, $body ) = mark_attendance_over_http( [ 'not', 'a', 'hash' ] );

    is $status, 400, 'refused';
    ok $body->{error}, 'with a reason';
};

subtest 'staff user cannot access admin-only routes' => sub {
    $t->get_ok('/admin/domains')
      ->status_is(403, 'Staff cannot access admin-only domain management');
};
