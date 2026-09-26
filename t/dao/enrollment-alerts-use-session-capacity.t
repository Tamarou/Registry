#!/usr/bin/env perl
# ABOUTME: The "nearly full" alert measures enrolment against the session's capacity.
# ABOUTME: It divided by events.capacity, which is almost always NULL, so it never fired.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw(diag done_testing is ok subtest)];
defer { done_testing };

use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw(days_from_now);
use Registry::DAO;
use Registry::DAO::AdminDashboard;
use Registry::DAO::Event;
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::DAO::Session;
use Registry::DAO::User;
use Registry::DAO::Family;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
Test::Registry::Fixtures::create_tenant( $dao->db, { name => 'Alert Studio', slug => 'alert_studio' } );
$dao->db->query( 'SELECT clone_schema(?)', 'alert_studio' );
my $db = Registry::DAO->new( url => $test_db->uri, schema => 'alert_studio' )->db;

my $teacher = Registry::DAO::User->create( $db, {
    username => 'alert_teacher', name => 'Alert Teacher',
    email => 'alert@test.local', user_type => 'staff' } );
my $parent = Registry::DAO::User->create( $db, {
    username => 'alert_parent', name => 'Alert Parent',
    email => 'alertp@test.local', user_type => 'parent' } );
my $location = Registry::DAO::Location->create( $db, {
    name => 'Alert Room', slug => 'alert-room',
    address_info => { street_address => '1 Alert St', city => 'Orlando', state => 'FL', postal_code => '32801' },
    metadata => {} } );
my $project = Registry::DAO::Project->create( $db, {
    name => 'Alert Programme', status => 'published', metadata => {} } );

# Four of five places taken: 80% is under the threshold, so this one must NOT
# be reported. The near-full session below is what should be.
my $session = Registry::DAO::Session->create( $db, {
    name => 'Nearly Full Session', slug => 'nearly-full',
    status => 'published', capacity => 5,
    start_date => days_from_now(14), end_date => days_from_now(28), metadata => {} } );

# The meeting carries NO capacity of its own -- the ordinary case, and the one
# that made this query return nothing at all.
my $event = Registry::DAO::Event->create( $db, {
    time => days_from_now(14) . ' 10:00:00', duration => 60,
    location_id => $location->id, project_id => $project->id,
    teacher_id => $teacher->id, metadata => {} } );
$session->add_events( $db, $event->id );

for my $i ( 1 .. 5 ) {
    my $child = Registry::DAO::Family->add_child( $db, $parent->id, {
        child_name => "Alert Kid $i", birth_date => '2016-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'ICE', phone => '555-0000' },
    } );
    $db->insert( 'enrollments', {
        session_id => $session->id, student_id => $child->id,
        family_member_id => $child->id, parent_id => $parent->id,
        status => 'active', metadata => '{}',
    } );
}

subtest 'a session at capacity is reported' => sub {
    my $alerts = Registry::DAO::AdminDashboard->get_enrollment_alerts($db);

    my ($mine) = grep { $_->{session_name} eq 'Nearly Full Session' } @$alerts;
    ok $mine, 'the full session raises an alert'
        or diag 'alerts returned: ' . scalar(@$alerts);
    is $mine && $mine->{capacity}, 5, 'measured against the session capacity';
    is $mine && $mine->{enrolled_count}, 5, 'with the real enrolment count';
};
