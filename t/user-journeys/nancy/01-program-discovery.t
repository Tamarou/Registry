#!/usr/bin/env perl
# ABOUTME: Nancy user journey: program discovery -- browse programs and sessions on the storefront
# ABOUTME: Tests the public tenant storefront workflow and session availability without authentication

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;

use Registry::DAO qw(Workflow);
use Registry::DAO::User;
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::DAO::Session;
use Registry::DAO::Event;
use Mojo::Home;
use YAML::XS qw(Load);

my $tdb = Test::Registry::DB->new;
my $db  = $tdb->db;
$ENV{DB_URL} = $tdb->uri;

# Seeded DB templates (from registry-landing-page-template) override the
# default filesystem storefront with a marketing landing page that doesn't
# list programs. Nancy is testing the program listing view, so remove the
# override here and let the default template render the seeded fixtures.
$db->db->query(
    q{DELETE FROM templates WHERE name = 'tenant-storefront/program-listing'}
);

# Import workflows
my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml($db, $file->slurp);
}

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $db } );

# Create a location (school) Nancy will browse
my $school = Test::Registry::Fixtures::create_location( $db, {
    name  => 'Riverside Elementary',
    slug  => 'riverside-elementary',
    notes => 'Home of the River Otters',
} );

# Create programs at this school
my $art_program = Test::Registry::Fixtures::create_project( $db, {
    name  => 'After School Arts',
    notes => 'Creative arts for grades 1-5',
} );

my $stem_program = Test::Registry::Fixtures::create_project( $db, {
    name  => 'STEM Explorers',
    notes => 'Science and technology after school',
} );

# Create a teacher user so events have an assigned teacher
my $teacher = Test::Registry::Fixtures::create_user( $db, {
    username  => 'nancy_disc_teacher',
    name      => 'Ms Rivera',
    email     => 'ms.rivera@riverside.edu',
    user_type => 'staff',
} );

# Create sessions for both programs (future dates for storefront visibility)
my $art_session = Test::Registry::Fixtures::create_session( $db, {
    name       => 'Fall 2026 Arts',
    start_date => '2026-09-01',
    end_date   => '2026-11-30',
    status     => 'published',
    capacity   => 20,
} );

my $stem_session = Test::Registry::Fixtures::create_session( $db, {
    name       => 'Fall 2026 STEM',
    start_date => '2026-09-01',
    end_date   => '2026-11-30',
    status     => 'published',
    capacity   => 15,
} );

# Create events that link sessions to programs and the location
my $art_event = Test::Registry::Fixtures::create_event( $db, {
    location_id => $school->id,
    project_id  => $art_program->id,
    teacher_id  => $teacher->id,
    capacity    => 20,
    time        => '2026-09-05 15:00:00',
    duration    => 90,
} );

my $stem_event = Test::Registry::Fixtures::create_event( $db, {
    location_id => $school->id,
    project_id  => $stem_program->id,
    teacher_id  => $teacher->id,
    capacity    => 15,
    time        => '2026-09-05 16:00:00',
    duration    => 90,
} );

# Associate events with sessions
$art_session->add_events( $db, $art_event->id );
$stem_session->add_events( $db, $stem_event->id );

subtest 'Storefront is accessible without authentication' => sub {
    $t->get_ok('/')
      ->status_is(200, 'Storefront returns 200');
};

subtest 'Storefront shows available programs' => sub {
    $t->get_ok('/')
      ->status_is(200)
      ->content_like( qr/After School Arts/i, 'Art program listed' )
      ->content_like( qr/STEM Explorers/i,    'STEM program listed' );
};

subtest 'Session data is present in the database' => sub {
    my $found_art = Registry::DAO::Session->find( $db, { name => 'Fall 2026 Arts' } );
    ok( $found_art,                     'Art session found in DB' );
    is( $found_art->status, 'published', 'Art session is published' );

    my $found_stem = Registry::DAO::Session->find( $db, { name => 'Fall 2026 STEM' } );
    ok( $found_stem,                      'STEM session found in DB' );
    is( $found_stem->status, 'published', 'STEM session is published' );
};

subtest 'Programs have events linked to school location' => sub {
    my $art_events  = $art_session->events($db);
    my $stem_events = $stem_session->events($db);

    ok( scalar(@$art_events)  > 0, 'Art session has events' );
    ok( scalar(@$stem_events) > 0, 'STEM session has events' );

    is( $art_events->[0]->location_id,  $school->id, 'Art event at correct location' );
    is( $stem_events->[0]->location_id, $school->id, 'STEM event at correct location' );
};

done_testing;
