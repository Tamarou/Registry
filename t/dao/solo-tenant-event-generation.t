#!/usr/bin/env perl
# ABOUTME: A tenant of one must be able to schedule without first hiring somebody.
# ABOUTME: events.teacher_id is NOT NULL and the teacher select only renders when staff exist.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw(diag done_testing is isnt ok subtest)];
defer { done_testing };

use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw(days_from_now);
use Registry::DAO;
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::DAO::User;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::WorkflowSteps::GenerateEvents;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
Test::Registry::Fixtures::create_tenant( $dao->db, { name => 'Solo Studio', slug => 'solo_studio' } );
$dao->db->query( 'SELECT clone_schema(?)', 'solo_studio' );
my $db = Registry::DAO->new( url => $test_db->uri, schema => 'solo_studio' )->db;

# The whole point: this tenant has exactly one person in it.
my $owner = Registry::DAO::User->create( $db, {
    username => 'solo_owner', name => 'Sam Solo',
    email => 'sam@solo.test', user_type => 'admin',
} );
is $db->query('SELECT count(*) AS n FROM users')->hash->{n}, 1,
    'the tenant really does contain one person';

my $project  = Registry::DAO::Project->create( $db, { name => 'Solo Pottery', status => 'published', metadata => {} } );
my $location = Registry::DAO::Location->create( $db, {
    name => 'Home Studio', slug => 'home-studio',
    address_info => { street_address => '2 Wheel Ln', city => 'Orlando', state => 'FL', postal_code => '32801' },
    metadata => {},
} );

my $workflow = Registry::DAO::Workflow->create( $db, {
    name => 'Solo Assignment', slug => 'solo-assignment', description => 'test',
} );
my $step = Registry::DAO::WorkflowSteps::GenerateEvents->create( $db, {
    workflow_id => $workflow->id, slug => 'generate-events',
    class => 'Registry::DAO::WorkflowSteps::GenerateEvents', description => 'generate',
} );
$workflow->update( $db, { first_step => 'generate-events' }, { id => $workflow->id } );

my $run = $workflow->new_run($db);
$run->update_data( $db, {
    project_id          => $project->id,
    project_name        => $project->name,
    project_description => 'thrown pots',
    # user_id is server-owned run data: the signed-in person driving the
    # workflow. The /:workflow guard means an admin surface always has one.
    user_id             => $owner->id,
    configured_locations => [ {
        id => $location->id, name => $location->name, capacity => 8,
        schedule => { tuesday => '18:00' }, pricing_override => 40,
    } ],
} );

subtest 'a solo operator can generate events with nobody else to assign' => sub {
    # No teacher_assignments at all -- exactly what the form submits when the
    # select never rendered because there are no other users.
    my $result = $step->process( $db, {
        confirm_generation => 1,
        generation_params  => { start_date => days_from_now(3), duration_weeks => 2 },
    }, $run );

    ok !$result->{errors}, 'generation did not fail'
        or diag 'errors: ' . join( '; ', ( $result->{errors} // [] )->@* );

    my $events = $db->query(
        'SELECT teacher_id FROM events WHERE project_id = ?', $project->id )->hashes->to_array;

    ok scalar(@$events), 'events were created';
    is scalar( grep { ( $_->{teacher_id} // '' ) eq $owner->id } @$events ), scalar(@$events),
        'and every one is taught by the only person in the tenant';
};

subtest 'an explicit choice still wins over the fallback' => sub {
    my $other = Registry::DAO::User->create( $db, {
        username => 'hired_help', name => 'Hired Help',
        email => 'help@solo.test', user_type => 'staff',
    } );
    # A second location, because the session name is derived as
    # "<project> at <location>" and sessions.name is unique.
    my $annexe = Registry::DAO::Location->create( $db, {
        name => 'The Annexe', slug => 'the-annexe',
        address_info => { street_address => '3 Kiln Way', city => 'Orlando', state => 'FL', postal_code => '32801' },
        metadata => {},
    } );

    my $run2 = $workflow->new_run($db);
    $run2->update_data( $db, {
        project_id => $project->id, project_name => $project->name,
        project_description => 'thrown pots', user_id => $owner->id,
        configured_locations => [ {
            id => $annexe->id, name => $annexe->name, capacity => 8,
            schedule => { thursday => '18:00' }, pricing_override => 40,
        } ],
    } );

    my $result = $step->process( $db, {
        confirm_generation  => 1,
        generation_params   => { start_date => days_from_now(4), duration_weeks => 1 },
        teacher_assignments => { $annexe->id => $other->id },
    }, $run2 );

    ok !$result->{errors}, 'generation did not fail'
        or diag 'errors: ' . join( '; ', ( $result->{errors} // [] )->@* );

    my $sid = $result->{created_sessions} ? $result->{created_sessions}[0]{session_id} : undef;
    $sid //= $db->query( 'SELECT id FROM sessions ORDER BY created_at DESC LIMIT 1' )->hash->{id};

    my $teachers = $db->query( <<~'SQL', $sid )->hashes->to_array;
        SELECT DISTINCT e.teacher_id FROM events e
          JOIN session_events se ON se.event_id = e.id
         WHERE se.session_id = ?
        SQL

    is scalar(@$teachers), 1, 'one teacher on the new session';
    is $teachers->[0]{teacher_id}, $other->id, 'the one who was chosen, not the owner';
};

# Morgan decides, per location, whether a full session collects a queue. The
# choice is made where capacity is set -- the same decision seen from the
# other side -- and has to reach the session that generation creates, or it
# is a control that does nothing.
subtest 'the waitlist choice reaches the session' => sub {
    my $off = Registry::DAO::Location->create( $db, {
        name => 'No Queue Room', slug => 'no-queue-room',
        address_info => { street_address => '9 Quiet Way', city => 'Orlando', state => 'FL', postal_code => '32801' },
        metadata => {},
    } );

    my $result = $step->process( $db, {
        confirm_generation => 1,
        generation_params  => { start_date => days_from_now(5), duration_weeks => 1 },
    }, do {
        my $r = $workflow->new_run($db);
        $r->update_data( $db, {
            project_id => $project->id, project_name => $project->name,
            project_description => 'thrown pots', user_id => $owner->id,
            configured_locations => [ {
                id => $off->id, name => $off->name, capacity => 8,
                schedule => { friday => '16:00' }, pricing_override => 40,
                waitlist_enabled => 0,
            } ],
        } );
        $r;
    } );

    ok !$result->{errors}, 'generation succeeded'
        or diag 'errors: ' . join( '; ', ( $result->{errors} // [] )->@* );

    my $row = $db->query(
        'SELECT waitlist_enabled FROM sessions WHERE id = ?',
        $result->{created_sessions}
            ? $result->{created_sessions}[0]{session_id}
            : $db->query( 'SELECT id FROM sessions ORDER BY created_at DESC LIMIT 1' )->hash->{id}
    )->hash;

    is $row->{waitlist_enabled}, 0, 'the session was created with its waitlist off';
};
