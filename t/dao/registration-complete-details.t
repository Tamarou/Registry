#!/usr/bin/env perl
# ABOUTME: The confirmation page must name the child and the session that was just paid for.
# ABOUTME: It read keys no step writes, so every camper read "N/A" and every session was blank.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::WorkflowSteps::RegistrationComplete;
use Registry::DAO::User;
use Registry::DAO::Family;
use Registry::DAO::Session;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

my $tenant = Test::Registry::Fixtures::create_tenant( $dao->db, {
    name => 'Complete Page Tenant', slug => 'complete_page',
} );
$dao->db->query( 'SELECT clone_schema(?)', 'complete_page' );
$dao = Registry::DAO->new( url => $test_db->uri, schema => 'complete_page' );
my $db = $dao->db;

my $parent = Registry::DAO::User->create( $db, {
    email => 'parent@complete.test', username => 'completeparent',
    name => 'Nancy Parent', user_type => 'parent',
} );

my $kylie = Registry::DAO::Family->add_child( $db, $parent->id, {
    child_name => 'Kylie', birth_date => '2016-03-15', grade => '3',
    medical_info => {}, emergency_contact => { name => 'N', phone => '555-0123' },
} );
my $rob = Registry::DAO::Family->add_child( $db, $parent->id, {
    child_name => 'Rob', birth_date => '2014-06-20', grade => '5',
    medical_info => {}, emergency_contact => { name => 'N', phone => '555-0123' },
} );

# Two sessions, so a page that renders one label for everyone is visibly wrong.
my $pottery = Registry::DAO::Session->create( $db, {
    name => 'Pottery Intensive', start_date => '2026-07-06', end_date => '2026-07-10',
    status => 'published', metadata => {},
} );
my $printmaking = Registry::DAO::Session->create( $db, {
    name => 'Printmaking Week', start_date => '2026-07-13', end_date => '2026-07-17',
    status => 'published', metadata => {},
} );

my $workflow = Registry::DAO::Workflow->create( $db, {
    name => 'Complete Page Workflow', slug => 'complete-page-workflow',
    description => 'Renders the confirmation page',
} );
Registry::DAO::WorkflowStep->create( $db, {
    workflow_id => $workflow->id, slug => 'complete',
    class => 'Registry::DAO::WorkflowSteps::RegistrationComplete',
    description => 'Registration Complete',
} );
$workflow->update( $db, { first_step => 'complete' }, { id => $workflow->id } );
$workflow = Registry::DAO::Workflow->find( $db, { id => $workflow->id } );

# Fetched the way the controller fetches it, so the class named in the workflow
# YAML has to actually load and dispatch -- not just exist on disk.
my $step = $workflow->first_step($db);
isa_ok $step, 'Registry::DAO::WorkflowSteps::RegistrationComplete';

# Exactly the shape MultiChildSessionSelection writes -- the page has to read
# the keys the workflow actually produces, which is the whole of this bug.
my $run = $workflow->new_run($db);
$run->update_data( $db, {
    children => [
        { id => $kylie->id, first_name => 'Kylie', last_name => '', grade => '3' },
        { id => $rob->id,   first_name => 'Rob',   last_name => '', grade => '5' },
    ],
    session_selections => {
        $kylie->id => $pottery->id,
        $rob->id   => $printmaking->id,
    },
} );

subtest 'the confirmation names each camper and the session they are in' => sub {
    my $data = $step->prepare_template_data( $db, $run );
    my $registrations = $data->{registrations};

    is ref $registrations, 'ARRAY', 'the page is given a list to render';
    is scalar $registrations->@*, 2, 'one entry per registered child';

    my %by_child = map { $_->{child_name} => $_ } $registrations->@*;

    is $by_child{Kylie}{grade}, '3', 'the grade comes from the run, not N/A';
    is $by_child{Kylie}{session}->name, 'Pottery Intensive', 'and her session is named';
    is $by_child{Kylie}{session}->start_date, '2026-07-06', 'with the dates she chose';
    is $by_child{Kylie}{session}->end_date,   '2026-07-10', 'both of them';

    # The sibling proves the page reads per-child selections rather than
    # labelling everyone with whatever the first child picked.
    is $by_child{Rob}{session}->name, 'Printmaking Week', 'the sibling gets his own session';
};

subtest 'a run with nothing selected renders no campers rather than dying' => sub {
    my $empty = $workflow->new_run($db);
    $empty->update_data( $db, { children => [], session_selections => {} } );

    my $data = $step->prepare_template_data( $db, $empty );
    is ref $data->{registrations}, 'ARRAY', 'still a list';
    is scalar $data->{registrations}->@*, 0, 'just an empty one';
};

done_testing;
