#!/usr/bin/env perl
# ABOUTME: The session-selection page must state the sibling rule it enforces and show its refusals.
# ABOUTME: It rendered neither: program_type was hardcoded undef (#422) and errors were never read (#372).
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Mojo;
use Test::Registry::Helpers qw( days_from_now birth_date_for_age );
use Registry;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::ProgramType;
use Registry::DAO::Project;
use Registry::DAO::Location;
use Registry::DAO::Event;
use Registry::DAO::Session;
use Registry::DAO::User;
use Registry::DAO::Family;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $location = Registry::DAO::Location->create( $db, {
    name => 'Rules Studio', slug => 'rules-studio', address_info => {}, metadata => {},
} );
my $teacher = Registry::DAO::User->create( $db, {
    username => 'rules_teacher', name => 'T', user_type => 'staff',
    email => 'rulest@test.local',
} );

# same_session_for_siblings is the whole point: process enforces it, and the
# screen has to say so before a parent picks two different sessions.
my $family_program = Registry::DAO::ProgramType->create( $db, {
    name => 'Family Program', slug => 'rules-family-program',
    config => { enrollment_rules => { same_session_for_siblings => 1 } },
} );
my $solo_program = Registry::DAO::ProgramType->create( $db, {
    name => 'Solo Program', slug => 'rules-solo-program',
    config => { enrollment_rules => { same_session_for_siblings => 0 } },
} );

sub a_project ($program_type) {
    state $n = 0;
    $n++;
    return Registry::DAO::Project->create( $db, {
        name => "Rules Project $n", status => 'published',
        program_type_slug => $program_type->slug, metadata => {},
    } );
}

# Dates relative to now, never literals: offered_sessions filters on
# `s.end_date >= CURRENT_DATE`, so a hardcoded date turns this file green today
# and silently empty later -- which is #368.
sub a_session ($project, $hour) {
    my $session = Registry::DAO::Session->create( $db, {
        name => "Rules Week $hour",
        start_date => days_from_now(30), end_date => days_from_now(37),
        status => 'published', capacity => 10, metadata => {},
    } );
    my $event = Registry::DAO::Event->create( $db, {
        time => days_from_now(30) . sprintf( ' %02d:00:00', $hour ), duration => 60,
        location_id => $location->id, project_id => $project->id,
        teacher_id => $teacher->id, capacity => 10, metadata => {},
    } );
    $session->add_events( $db, $event->id );
    return $session;
}

my $workflow = Registry::DAO::Workflow->create( $db, {
    name => 'Rules Workflow', slug => 'rules-workflow', description => 'd',
} );
Registry::DAO::WorkflowStep->create( $db, {
    workflow_id => $workflow->id, slug => 'session-selection',
    class => 'Registry::DAO::WorkflowSteps::MultiChildSessionSelection',
    description => 'Session selection',
} );
$workflow->update( $db, { first_step => 'session-selection' }, { id => $workflow->id } );
$workflow = Registry::DAO::Workflow->find( $db, { id => $workflow->id } );
my $step = $workflow->get_step( $db, { slug => 'session-selection' } );

my $parent = Registry::DAO::User->create( $db, {
    username => 'rules_parent', name => 'Rules Parent', user_type => 'parent',
    email => 'rules@test.local',
} );
my @kids = map {
    Registry::DAO::Family->add_child( $db, $parent->id, {
        child_name => $_, birth_date => birth_date_for_age(8), grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
    } )
} ( 'Alice', 'Bob' );

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $dao } );

sub render_for ( $project, $children, %extra ) {
    my $run = $workflow->new_run($db);
    $run->update_data( $db, {
        user_id            => $parent->id,
        selected_child_ids => [ map { $_->id } @$children ],
        location_id        => $location->id,
        program_id         => $project->id,
    } );

    return $t->app->build_controller->render_to_string(
        template => 'summer-camp-registration/session-selection',
        action   => '/rules-probe',
        workflow => 'rules-workflow',   # the Back link needs the slug
        run      => $run,
        %{ $step->prepare_template_data( $db, $run ) },
        %extra,
    );
}

subtest 'the step resolves the programme type the gate enforces' => sub {
    my $project = a_project($family_program);
    a_session( $project, 9 );

    my $run = $workflow->new_run($db);
    $run->update_data( $db, {
        user_id            => $parent->id,
        selected_child_ids => [ map { $_->id } @kids ],
        location_id        => $location->id,
        program_id         => $project->id,
    } );

    my $data = $step->prepare_template_data( $db, $run );
    ok $data->{program_type}, 'the page is told which programme type this is';
    is $data->{program_type}->slug, 'rules-family-program', 'the right one';
    ok $data->{program_type}->same_session_for_siblings,
        'and that it is the one with the sibling rule';
};

subtest 'siblings under one rule are offered one session, and told why' => sub {
    my $project = a_project($family_program);
    my $session = a_session( $project, 10 );

    my $html = render_for( $project, \@kids );

    like $html, qr/All siblings must be enrolled in the same/,
        'the rule is stated before the parent chooses';
    like $html, qr/name="session_all"/,
        'and there is one control for the whole family';
    unlike $html, qr/name="session_for_@{[ $kids[0]->id ]}"/,
        'not a per-child picker inviting the choice the gate will refuse';
};

subtest 'without the rule each child still picks their own' => sub {
    # The other side of the branch: resolving the programme type must not turn
    # every registration into a single-session one.
    my $project = a_project($solo_program);
    a_session( $project, 11 );

    my $html = render_for( $project, \@kids );

    unlike $html, qr/All siblings must be enrolled in the same/,
        'no rule is claimed that does not apply';
    like $html, qr/name="session_for_@{[ $kids[0]->id ]}"/, 'Alice picks her own';
    like $html, qr/name="session_for_@{[ $kids[1]->id ]}"/, 'and Bob his';
};

subtest 'a refusal appears on the page it sends the parent back to' => sub {
    my $project = a_project($solo_program);
    a_session( $project, 12 );

    # Exactly what the controller puts in the stash from flash(validation_errors)
    # after the step refuses: the page read neither key, so the parent got their
    # form back unchanged with their selection gone.
    my $html = render_for( $project, \@kids, errors => [
        'Rules Week 12 is full. Please select a different session for Alice',
        'Bob (age 3) is not eligible for this program (ages 5-11)',
    ] );

    like $html, qr/Please correct the following/, 'the page says something is wrong';
    like $html, qr/Rules Week 12 is full/,        'and which session was full';
    like $html, qr/not eligible for this program/, 'and which child was refused';
};

subtest 'no errors renders no error box' => sub {
    my $project = a_project($solo_program);
    a_session( $project, 13 );

    my $html = render_for( $project, \@kids );
    unlike $html, qr/Please correct the following/,
        'a first visit is not greeted as a mistake';
};

done_testing;
