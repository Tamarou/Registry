#!/usr/bin/env perl
# ABOUTME: A session generated from a location assignment must carry its own date range.
# ABOUTME: The storefront filters on session end_date, so a session without one is unsellable.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw(diag done_testing is isnt like note ok subtest)];
defer { done_testing };

use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw(days_from_now);
use Registry::DAO;
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::DAO::User;
use Registry::DAO::WorkflowSteps::GenerateEvents;
use Registry::DAO::WorkflowSteps::ProgramListing;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

Test::Registry::Fixtures::create_tenant( $dao->db, {
    name => 'Date Range Studio', slug => 'date_range',
} );
$dao->db->query( 'SELECT clone_schema(?)', 'date_range' );
my $db = Registry::DAO->new( url => $test_db->uri, schema => 'date_range' )->db;

my $project = Registry::DAO::Project->create( $db, {
    name => 'Clay Club', status => 'published', metadata => {},
} );
my $location = Registry::DAO::Location->create( $db, {
    name => 'The Annex', slug => 'the-annex',
    address_info => { street_address => '1 Kiln Row', city => 'Orlando', state => 'FL', postal_code => '32801' },
    metadata => {},
} );

# events.teacher_id is NOT NULL, so generation only works with a teacher --
# the step's own signature defaults it to undef, which cannot succeed.
my $teacher = Registry::DAO::User->create( $db, {
    username => 'clay_teacher', name => 'Clay Teacher',
    email => 'clay@test.local', user_type => 'staff',
} );

my $step = Registry::DAO::WorkflowSteps::GenerateEvents->new(
    id => 1, slug => 'generate-events', workflow_id => 1,
    description => 'test', class => 'Registry::DAO::WorkflowSteps::GenerateEvents',
);

# Dates derived, never written down -- a fixture pinned to a literal stops
# testing what it says the day it expires (#368).
my $start = days_from_now(7);

my $result = $step->create_session_for_location(
    $db,
    { project_id => $project->id, project_name => $project->name, project_description => 'clay' },
    { id => $location->id, name => $location->name, capacity => 12,
      schedule => { monday => '10:00', wednesday => '10:00' },
      pricing_override => 100 },
    { start_date => $start, duration_weeks => 3 },
    $teacher->id,
);

ok !$result->{error}, 'the generation step succeeded'
    or diag 'step error: ' . ( $result->{error} // '(none reported)' );
ok $result->{events_created} > 0, 'it generated events';

subtest 'the session carries the range of the events generated for it' => sub {
    my $row = $db->select( 'sessions', [qw(start_date end_date)], { id => $result->{session_id} } )->hash;

    isnt $row->{start_date}, undef, 'start_date is set';
    isnt $row->{end_date},   undef, 'end_date is set';

    # Against the events themselves, not against the parameters, so a range
    # that disagrees with what was actually created fails.
    my $span = $db->query( <<~'SQL', $result->{session_id} )->hash;
        SELECT MIN(e.time)::date AS first, MAX(e.time)::date AS last
          FROM events e
          JOIN session_events se ON se.event_id = e.id
         WHERE se.session_id = ?
        SQL

    is $row->{start_date}, $span->{first}, 'start_date is the first event';
    is $row->{end_date},   $span->{last},  'end_date is the last event';

    # Three weeks of Monday+Wednesday must not collapse to a single day.
    isnt $row->{start_date}, $row->{end_date}, 'and the range spans the programme';
};

subtest 'and the storefront can therefore list it' => sub {
    $db->query( 'UPDATE sessions SET status = ? WHERE id = ?', 'published', $result->{session_id} );
    $db->query( 'UPDATE projects SET status = ? WHERE id = ?', 'published', $project->id );

    # The real storefront step, not the admin overview: ProgramListing is what
    # filters s.end_date >= CURRENT_DATE, and that predicate is what silently
    # dropped a dateless session.
    my $listing = Registry::DAO::WorkflowSteps::ProgramListing->new(
        id => 2, slug => 'listing', workflow_id => 1,
        description => 'test', class => 'Registry::DAO::WorkflowSteps::ProgramListing',
    );
    my $data = $listing->prepare_template_data( $db, undef, {} );

    my @names = map { $_->{project}->name } ( $data->{programs} // [] )->@*;
    ok scalar( grep { $_ eq 'Clay Club' } @names ),
        'a parent can see the programme on the storefront'
        or diag 'storefront listed: ' . ( join( ', ', @names ) || '(nothing)' );
};
