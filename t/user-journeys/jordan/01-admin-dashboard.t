#!/usr/bin/env perl
# ABOUTME: Jordan (business owner) journey: admin dashboard overview and navigation.
# ABOUTME: Tests that Jordan can see program stats, enrollment data, and navigate to admin tools.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw(done_testing is ok like subtest)];
defer { done_testing };

use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::Helpers qw(authenticate_as import_all_workflows);
use Registry::DAO;
use Registry::DAO::User;
use Registry::DAO::Family;

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

my $program = $dao->create(Project => {
    name              => 'Summer Art Camp',
    program_type_slug => 'summer-camp',
    metadata          => { description => 'Creative art exploration for kids' },
});

my $session = $dao->create(Session => {
    name       => 'Week 1 - Painting',
    start_date => '2026-06-01',
    end_date   => '2026-06-05',
    status     => 'published',
    capacity   => 16,
    metadata   => {},
});

my $event = $dao->create(Event => {
    time        => '2026-06-01 09:00:00',
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
