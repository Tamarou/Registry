#!/usr/bin/env perl
# ABOUTME: UI test for the admin dashboard publish/unpublish controls.
# ABOUTME: Each program card should expose a button that toggles status.
use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Registry;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw(authenticate_as);
use Registry::DAO::Project;
use Registry::DAO::Session;
use Registry::DAO::Event;
use Registry::DAO::Location;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

my $t = Test::Registry::Mojo->new('Registry');

my $admin = $dao->create(User => {
    username  => 'publish_ui_admin',
    name      => 'Admin',
    email     => 'admin@test.local',
    user_type => 'admin',
    password  => 'x',
});
authenticate_as($t, $admin);

# A program with at least one session/event so get_program_overview will
# actually return it.
my $location = $dao->create(Location => {
    name         => 'UI Test Location',
    address_info => {},
    metadata     => {},
});

my $program = $dao->create(Project => {
    name   => 'Draft UI Program',
    status => 'draft',
});

# Session must overlap CURRENT_DATE for get_program_overview('current')
# to include it -- dashboard-overview loads the 'current' range by default.
use DateTime;
my $today = DateTime->now->ymd;
my $next_year = DateTime->now->add(years => 1)->ymd;
my $session = $dao->create(Session => {
    name       => 'Draft UI Session',
    start_date => $today,
    end_date   => $next_year,
    status     => 'published',
    capacity   => 10,
});

my $event = $dao->create(Event => {
    session_id  => $session->id,
    time        => '2099-09-05 15:00:00',
    duration    => 60,
    location_id => $location->id,
    project_id  => $program->id,
    teacher_id  => $admin->id,
});

# The program_overview partial is rendered as part of the admin-dashboard
# workflow (admin-dashboard/dashboard-overview.html.ep includes it). Hit
# the full workflow page and assert the publish controls are there.
subtest 'admin dashboard program overview shows publish button for draft' => sub {
    $t->get_ok('/admin/dashboard')
      ->status_is(200)
      ->content_like(qr/Draft UI Program/, 'program listed')
      ->content_like(qr/hx-post="\/admin\/programs\/\Q@{[ $program->id ]}\E\/status"/,
                     'publish form posts to program status endpoint')
      ->content_like(qr{<input type="hidden" name="status" value="published">},
                     'draft program offers Publish action')
      ->content_like(qr/>Publish</, 'button labelled Publish');
};

subtest 'admin dashboard shows unpublish button for published program' => sub {
    $program->update($dao->db, { status => 'published' });

    $t->get_ok('/admin/dashboard')
      ->status_is(200)
      ->content_like(qr{<input type="hidden" name="status" value="draft">},
                     'published program offers Unpublish action')
      ->content_like(qr/>Unpublish</, 'button labelled Unpublish');
};

done_testing();
