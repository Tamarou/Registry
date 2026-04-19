#!/usr/bin/env perl
# ABOUTME: Verifies that ProgramListing filters out unpublished programs.
# ABOUTME: Parents should only see programs where projects.status = 'published'.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::User;
use Registry::DAO::Project;
use Registry::DAO::Location;
use Registry::DAO::Session;
use Registry::DAO::Event;
use Registry::DAO::WorkflowSteps::ProgramListing;

my $tdb = Test::Registry::DB->new;
my $dao = $tdb->db;
my $db  = $dao->db;

my $tenant = Test::Registry::Fixtures::create_tenant($db, {
    name => 'Storefront Filter Tenant',
    slug => 'storefront_filter',
});
$db->query('SELECT clone_schema(?)', 'storefront_filter');

my $tenant_dao = Registry::DAO->new(url => $tdb->uri, schema => 'storefront_filter');
my $tdb_conn   = $tenant_dao->db;

# Common fixtures: location and teacher.
my $location = Registry::DAO::Location->create($tdb_conn, {
    name         => 'Downtown Studio',
    address_info => {},
});

my $teacher = Registry::DAO::User->create($tdb_conn, {
    name     => 'Alex Teacher',
    username => 'alex_t',
    email    => 'alex@test.local',
    user_type => 'staff',
    password  => 'x',
});

# Published program with a published session.
my $published_program = Registry::DAO::Project->create($tdb_conn, {
    name   => 'Published Art',
    notes  => 'Visible to parents',
    status => 'published',
});
my $published_session = Registry::DAO::Session->create($tdb_conn, {
    name       => 'Published Art Fall',
    start_date => '2099-09-01',
    end_date   => '2099-12-15',
    status     => 'published',
    capacity   => 10,
});
my $published_event = Registry::DAO::Event->create($tdb_conn, {
    session_id => $published_session->id,
    time       => '2099-09-05 15:00:00',
    duration   => 60,
    location_id => $location->id,
    project_id  => $published_program->id,
    teacher_id  => $teacher->id,
});

# Draft program with a published session -- should still be hidden
# because the program itself isn't published.
my $draft_program = Registry::DAO::Project->create($tdb_conn, {
    name   => 'Draft STEM',
    notes  => 'Not yet live',
    status => 'draft',
});
my $draft_program_session = Registry::DAO::Session->create($tdb_conn, {
    name       => 'Draft STEM Fall',
    start_date => '2099-09-01',
    end_date   => '2099-12-15',
    status     => 'published',
    capacity   => 10,
});
my $draft_program_event = Registry::DAO::Event->create($tdb_conn, {
    session_id  => $draft_program_session->id,
    time        => '2099-09-06 15:00:00',
    duration    => 60,
    location_id => $location->id,
    project_id  => $draft_program->id,
    teacher_id  => $teacher->id,
});

# Published program with a draft session -- program is visible but
# session should not be listed. ProgramListing already filters
# sessions; this test asserts the program level.
my $pub_with_draft_session = Registry::DAO::Project->create($tdb_conn, {
    name   => 'Partial Publish',
    notes  => 'Only some sessions ready',
    status => 'published',
});
my $pub_draft_session = Registry::DAO::Session->create($tdb_conn, {
    name       => 'Partial Publish Fall',
    start_date => '2099-09-01',
    end_date   => '2099-12-15',
    status     => 'draft',
    capacity   => 10,
});
my $pub_draft_session_event = Registry::DAO::Event->create($tdb_conn, {
    session_id  => $pub_draft_session->id,
    time        => '2099-09-07 15:00:00',
    duration    => 60,
    location_id => $location->id,
    project_id  => $pub_with_draft_session->id,
    teacher_id  => $teacher->id,
});

# Build a minimal workflow run for prepare_template_data.
my $workflow = Registry::DAO::Workflow->create($tdb_conn, {
    name        => 'Filter Test Workflow',
    slug        => 'storefront_filter_test',
    description => 'Smoke test',
    first_step  => 'program-listing',
});
$workflow->add_step($tdb_conn, {
    slug        => 'program-listing',
    description => 'Browse',
    class       => 'Registry::DAO::WorkflowSteps::ProgramListing',
});

my $step = Registry::DAO::WorkflowStep->find($tdb_conn, {
    workflow_id => $workflow->id,
    slug        => 'program-listing',
});
my $run = $workflow->new_run($tdb_conn);

my $data = $step->prepare_template_data($tdb_conn, $run);

subtest 'only published programs appear in the listing' => sub {
    my @names = map { $_->{project}->name } @{ $data->{programs} };
    ok( (grep { $_ eq 'Published Art' } @names),
        'Published program is listed');
    ok( !(grep { $_ eq 'Draft STEM' } @names),
        'Draft program is hidden (even with a published session)');
};

subtest 'draft sessions are hidden under published programs' => sub {
    my ($partial) = grep { $_->{project}->name eq 'Partial Publish' }
                    @{ $data->{programs} };

    # Partial Publish has one draft session. Since ProgramListing already
    # filters sessions by status, the program should not appear at all
    # (no published sessions means no rows join).
    ok( !$partial,
        'Published program with only draft sessions is hidden');
};

subtest 'filter dropdown locations only include published programs' => sub {
    # Create a separate location used ONLY by the draft program so we
    # can prove filtering works. Downtown Studio is also used by the
    # published program and would appear either way.
    my $draft_only_location = Registry::DAO::Location->create($tdb_conn, {
        name         => 'Draft Only Studio',
        address_info => {},
    });

    my $extra_draft_session = Registry::DAO::Session->create($tdb_conn, {
        name       => 'Draft STEM Afternoon',
        start_date => '2099-09-01',
        end_date   => '2099-12-15',
        status     => 'published',
        capacity   => 10,
    });
    Registry::DAO::Event->create($tdb_conn, {
        session_id  => $extra_draft_session->id,
        time        => '2099-09-07 15:00:00',
        duration    => 60,
        location_id => $draft_only_location->id,
        project_id  => $draft_program->id,
        teacher_id  => $teacher->id,
    });

    my $refreshed = $step->prepare_template_data($tdb_conn, $run);
    my @locations = map { $_->{name} } @{ $refreshed->{filter_locations} };
    ok( !(grep { $_ eq 'Draft Only Studio' } @locations),
        'Location only used by draft programs is not offered as a filter');
};

done_testing();
