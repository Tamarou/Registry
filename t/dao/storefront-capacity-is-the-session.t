#!/usr/bin/env perl
# ABOUTME: Places left on the storefront count against the SESSION's capacity.
# ABOUTME: A meeting's own capacity is a room limit and answers a different question.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw(done_testing is ok subtest)];
defer { done_testing };

use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw(days_from_now);
use Registry::DAO;
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::DAO::Session;
use Registry::DAO::Event;
use Registry::DAO::User;
use Registry::DAO::WorkflowSteps::ProgramListing;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
Test::Registry::Fixtures::create_tenant( $dao->db, { name => 'Cap Studio', slug => 'cap_studio' } );
$dao->db->query( 'SELECT clone_schema(?)', 'cap_studio' );
my $db = Registry::DAO->new( url => $test_db->uri, schema => 'cap_studio' )->db;

my $teacher = Registry::DAO::User->create( $db, {
    username => 'cap_teacher', name => 'Cap Teacher',
    email => 'cap@test.local', user_type => 'staff',
} );
my $location = Registry::DAO::Location->create( $db, {
    name => 'Cap Room', slug => 'cap-room',
    address_info => { street_address => '1 Cap St', city => 'Orlando', state => 'FL', postal_code => '32801' },
    metadata => {},
} );
my $project = Registry::DAO::Project->create( $db, {
    name => 'Cap Programme', status => 'published', metadata => {},
} );

# A session for twenty, meeting three times -- and ONE of those meetings is in
# a smaller room. The room limit is a fact about that meeting, not about how
# many children may enrol in the course.
my $session = Registry::DAO::Session->create( $db, {
    name => 'Cap Session', slug => 'cap-session',
    status => 'published', capacity => 20,
    # Derived, never written down: the storefront filters on end_date >=
    # CURRENT_DATE, so a pinned date stops testing what it says the day it
    # passes -- which it just did (#368).
    start_date => days_from_now(7), end_date => days_from_now(21), metadata => {},
} );

my $slot = 0;
for my $room_limit ( undef, 8, undef ) {
    my $event = Registry::DAO::Event->create( $db, {
        time => days_from_now( 7 + $slot++ ) . ' 10:00:00',
        duration => 60, location_id => $location->id, project_id => $project->id,
        teacher_id => $teacher->id, metadata => {},
        ( defined $room_limit ? ( capacity => $room_limit ) : () ),
    } );
    $session->add_events( $db, $event->id );
}

subtest 'the storefront counts places against the session, not a room' => sub {
    my $listing = Registry::DAO::WorkflowSteps::ProgramListing->new(
        id => 1, slug => 'listing', workflow_id => 1,
        description => 'test', class => 'Registry::DAO::WorkflowSteps::ProgramListing',
    );
    my $data = $listing->prepare_template_data( $db, undef, {} );

    my ($prog) = grep { $_->{project}->name eq 'Cap Programme' } ( $data->{programs} // [] )->@*;
    ok $prog, 'the programme is listed';
    my ($sess) = grep { $_->{session}->id eq $session->id } ( $prog->{sessions} // [] )->@*;
    ok $sess, 'with its session';

    # 20, not 8. The smaller room bounds who can be in the room that week; it
    # does not bound who may enrol in the course. Reading the meeting's number
    # here answers the enrolment question with a room number.
    is $sess->{capacity}, 20, 'capacity is the session capacity';
    is $sess->{available_spots}, 20, 'and every place is still open';
    ok !$sess->{is_full}, 'so it is not full';
};
