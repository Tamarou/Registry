#!/usr/bin/env perl
# ABOUTME: Jordan (business owner) journey: admin dashboard overview and navigation.
# ABOUTME: Tests that Jordan can see program stats, enrollment data, and navigate to admin tools.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw(done_testing diag is ok like subtest)];
defer { done_testing };

use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::Helpers qw(authenticate_as import_all_workflows days_from_now);
use Registry::DAO;
use Registry::DAO::User;
use Registry::DAO::Family;
use Registry::DAO::Enrollment;
use Registry::DAO::Session;

my $test_db = Test::Registry::DB->new;
my $dao = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

import_all_workflows($dao);

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

# --- Test Data Setup ---

my $jordan = $dao->create(User => {
    username  => 'jordan_owner',
    name      => 'Jordan Rivera',
    email     => 'jordan@tinyartempire.com',
    user_type => 'admin',
});

my $location = $dao->create(Location => {
    name         => 'Main Studio',
    slug         => 'main-studio',
    address_info => { street => '100 Art Lane', city => 'Orlando', state => 'FL' },
    metadata     => {},
});

my $teacher = $dao->create(User => {
    username  => 'amara_teacher',
    name      => 'Amara Chen',
    email     => 'amara@tinyartempire.com',
    user_type => 'staff',
});

my $program = $dao->create(Project => { status => 'published',
    name              => 'Summer Art Camp',
    program_type_slug => 'summer-camp',
    metadata          => { description => 'Creative art exploration for kids' },
});

my $session = $dao->create(Session => {
    name       => 'Week 1 - Painting',
    start_date => days_from_now(-2),
    end_date   => days_from_now(2),
    status     => 'published',
    capacity   => 16,
    metadata   => {},
});

my $event = $dao->create(Event => {
    time        => days_from_now(0) . ' 09:00:00',
    duration    => 420,
    location_id => $location->id,
    project_id  => $program->id,
    teacher_id  => $teacher->id,
    capacity    => 16,
    metadata    => {},
});
$session->add_events($dao->db, $event->id);

# Create a parent with enrolled child
my $parent = $dao->create(User => {
    username  => 'nancy_parent',
    name      => 'Nancy Martinez',
    email     => 'nancy@example.com',
    user_type => 'parent',
});

my $child = Registry::DAO::Family->add_child($dao->db, $parent->id, {
    child_name        => 'Liam Martinez',
    birth_date        => '2017-09-01',
    grade             => '3',
    medical_info      => {},
    emergency_contact => { name => 'Nancy', phone => '407-555-0123' },
});

$dao->db->insert('enrollments', {
    session_id       => $session->id,
    student_id       => $parent->id,
    family_member_id => $child->id,
    parent_id        => $parent->id,
    status           => 'active',
    metadata         => '{}',
});

# Authenticate as Jordan
authenticate_as($t, $jordan);

# === Jordan's Dashboard Journey ===

subtest 'Jordan can access admin dashboard' => sub {
    $t->get_ok('/admin/dashboard')
      ->status_is(200)
      ->content_like(qr/Admin Dashboard/, 'Dashboard title is rendered');
};

subtest 'Dashboard shows navigation with admin links' => sub {
    $t->get_ok('/admin/dashboard')
      ->status_is(200)
      ->element_exists('nav.dashboard-nav', 'Navigation bar present')
      ->element_exists('nav.dashboard-nav a[href="/program-creation"]', 'Link to create programs')
      ->element_exists('nav.dashboard-nav a[href="/admin/templates"]', 'Link to template editor')
      ->element_exists('nav.dashboard-nav a[href="/admin/domains"]', 'Link to domain management')
      ->content_like(qr/Jordan Rivera/, 'Shows Jordan\'s name in nav');
};

# What an admin opens the dashboard to find out: what is happening today.
# The suite asserted the page rendered and never that it listed anything, so it
# would have passed against a query returning nothing.
subtest "today's events lists the session running today" => sub {
    $t->get_ok("/admin/dashboard/todays_events?date=" . days_from_now(0))
      ->status_is(200)
      ->content_like(qr/Week 1 - Painting/, 'the session running today is named');
};

subtest 'the dashboard reports the enrollment that exists' => sub {
    $t->get_ok('/admin/dashboard/program_overview')
      ->status_is(200)
      ->content_like(qr/Summer Art Camp/, 'the seeded program is listed');
};

# The admin's queue. A drop request has to appear in it, and stop appearing
# once it is resolved -- a list that never empties is as useless as one that
# never fills.
subtest 'a pending drop request appears in the queue and leaves it when resolved' => sub {
    my $enrollment = Registry::DAO::Enrollment->find( $dao->db,
        { session_id => $session->id, family_member_id => $child->id } );

    my $request = $enrollment->request_drop( $dao->db, $parent, 'Family moving', 0 );
    ok $request, 'a parent raised a drop request';

    $t->get_ok('/admin/dashboard/pending_drop_requests')
      ->status_is(200)
      ->content_like(qr/Liam Martinez/, 'the child is named in the queue');

    $request->approve( $dao->db, $jordan, 'Approved' );

    $t->get_ok('/admin/dashboard/pending_drop_requests')
      ->status_is(200)
      ->content_unlike(qr/Liam Martinez/, 'and is gone once approved');
};

# Publishing is the admin's core action, and the only one that changes what a
# parent can see. Asserting the response alone would pass against a handler
# that answered 200 and wrote nothing.
subtest 'unpublishing a session changes the row, not just the response' => sub {
    $t->post_ok( "/admin/sessions/${\$session->id}/status" => form => { status => 'draft' } )
      ->status_is(200);

    is Registry::DAO::Session->find( $dao->db, { id => $session->id } )->status,
        'draft', 'the session is now a draft';

    $t->post_ok( "/admin/sessions/${\$session->id}/status" => form => { status => 'published' } )
      ->status_is(200);

    is Registry::DAO::Session->find( $dao->db, { id => $session->id } )->status,
        'published', 'and published again';
};

subtest 'a status the handler does not recognise is refused' => sub {
    $t->post_ok( "/admin/sessions/${\$session->id}/status" => form => { status => 'sideways' } )
      ->status_is(400);

    is Registry::DAO::Session->find( $dao->db, { id => $session->id } )->status,
        'published', 'and the row is untouched';
};

subtest 'Jordan can navigate to program creation' => sub {
    $t->get_ok('/program-creation')
      ->status_is(200)
      ->content_like(qr/program|Program/, 'Program creation page rendered');
};

subtest 'Jordan can access template editor' => sub {
    $t->get_ok('/admin/templates')
      ->status_is(200);
};

subtest 'Jordan can access domain management' => sub {
    $t->get_ok('/admin/domains')
      ->status_is(200);
};
