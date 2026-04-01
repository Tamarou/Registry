#!/usr/bin/env perl
# ABOUTME: Nancy user journey: schedule management -- view parent dashboard, upcoming events, recent attendance
# ABOUTME: Tests authenticated parent dashboard routes and event/attendance query methods

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;

use Registry::DAO::User;
use Registry::DAO::MagicLinkToken;
use Registry::DAO::FamilyMember;
use Registry::DAO::Enrollment;
use Registry::DAO::Session;

my $tdb = Test::Registry::DB->new;
my $db  = $tdb->db;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $db } );

# Create tenant
my $tenant = Test::Registry::Fixtures::create_tenant( $db, {
    name => 'Nancy Schedule School',
    slug => 'nancy_schedule',
} );

$db->schema( $tenant->slug );

# Build test data: location, program, session, event
my $location = Test::Registry::Fixtures::create_location( $db, {
    name => 'Oak Park School',
    slug => 'oak-park',
} );

my $program = Test::Registry::Fixtures::create_project( $db, {
    name  => 'Drama Club',
    notes => 'After-school theater arts',
} );

my $teacher = Test::Registry::Fixtures::create_user( $db, {
    username  => 'nancy_sched_teacher',
    name      => 'Ms Nguyen',
    email     => 'ms.nguyen@oakpark.edu',
    user_type => 'staff',
} );

my $session = Test::Registry::Fixtures::create_session( $db, {
    name       => 'Fall 2025 Drama',
    start_date => '2025-09-01',
    end_date   => '2025-11-30',
    status     => 'published',
    capacity   => 18,
} );

my $event = Test::Registry::Fixtures::create_event( $db, {
    location_id => $location->id,
    project_id  => $program->id,
    teacher_id  => $teacher->id,
    capacity    => 18,
    time        => '2025-09-05 15:30:00',
    duration    => 60,
} );

$session->add_events( $db, $event->id );

# Create Nancy as parent and enroll her child
my $nancy = Registry::DAO::User->create( $db->db, {
    username  => 'nancy.sched',
    name      => 'Nancy Schedule',
    email     => 'nancy.sched@family.example',
    user_type => 'parent',
} );

my $child = Registry::DAO::FamilyMember->create( $db->db, {
    family_id  => $nancy->id,
    child_name => 'Mia Schedule',
    birth_date => '2015-07-20',
    grade      => '4th',
} );

Registry::DAO::Enrollment->create( $db->db, {
    session_id       => $session->id,
    student_id       => $child->id,
    student_type     => 'family_member',
    family_member_id => $child->id,
    parent_id        => $nancy->id,
    status           => 'active',
} );

# Helper: log Nancy in via magic link
my sub login_nancy () {
    my ( $token_obj, $plaintext ) = Registry::DAO::MagicLinkToken->generate( $db->db, {
        user_id => $nancy->id,
        purpose => 'login',
    } );

    $t->get_ok("/auth/magic/$plaintext");
    $t->post_ok("/auth/magic/$plaintext/complete")->status_is(302);
}

login_nancy();

subtest 'Unauthenticated access to dashboard is rejected' => sub {
    # Use a fresh Test::Registry::Mojo instance with no session
    my $t2 = Test::Registry::Mojo->new('Registry');
    $t2->app->helper( dao => sub { $db } );

    $t2->get_ok('/parent/dashboard')
       ->status_is(302, 'Unauthenticated user is redirected to login');
};

subtest 'Unauthenticated access to upcoming events is rejected' => sub {
    my $t2 = Test::Registry::Mojo->new('Registry');
    $t2->app->helper( dao => sub { $db } );

    $t2->get_ok('/parent/dashboard/upcoming_events')
       ->status_is(302, 'Unauthenticated user is redirected');
};

subtest 'Authenticated parent can load the dashboard' => sub {
    $t->get_ok('/parent/dashboard')
      ->status_is(200, 'Parent dashboard returns 200');
};

subtest 'Authenticated parent can load upcoming events endpoint' => sub {
    $t->get_ok('/parent/dashboard/upcoming_events')
      ->status_is(200, 'Upcoming events endpoint returns 200');
};

subtest 'Authenticated parent can load recent attendance endpoint' => sub {
    $t->get_ok('/parent/dashboard/recent_attendance')
      ->status_is(200, 'Recent attendance endpoint returns 200');
};

subtest 'Authenticated parent can load unread messages count' => sub {
    $t->get_ok('/parent/dashboard/unread_messages_count')
      ->status_is(200, 'Unread messages count endpoint returns 200')
      ->json_is('/unread_count', 0, 'New parent has zero unread messages');
};

subtest 'Session is published and linked to events' => sub {
    my $found = Registry::DAO::Session->find( $db, { name => 'Fall 2025 Drama' } );
    ok( $found, 'Session found in DB' );
    is( $found->status, 'published', 'Session is published' );

    my $events = $found->events($db);
    ok( scalar(@$events) >= 1, 'Session has at least one event' );
};

subtest 'Child is enrolled in session' => sub {
    my $enrollment = Registry::DAO::Enrollment->find( $db->db, {
        family_member_id => $child->id,
        session_id       => $session->id,
    } );

    ok( $enrollment,                       'Enrollment exists for Mia' );
    is( $enrollment->status, 'active',     'Enrollment is active' );
    is( $enrollment->parent_id, $nancy->id, 'Linked to Nancy' );
};

subtest 'Children are linked to parent' => sub {
    my $children = Registry::DAO::FamilyMember->get_children_for_parent( $db->db, $nancy->id );
    ok( scalar(@$children) >= 1, 'At least one child found for parent' );
    my ($mia) = grep { $_->{child_name} eq 'Mia Schedule' } @$children;
    ok( $mia, 'Mia appears in children list' );
};

subtest 'Enrollment count for session is correct' => sub {
    my $count = Registry::DAO::Enrollment->count_for_session(
        $db->db, $session->id, ['active', 'pending']
    );
    is( $count, 1, 'One enrollment counted for session' );
};

done_testing;
