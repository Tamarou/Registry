#!/usr/bin/env perl
# ABOUTME: DAO-level tests for the program-type-management workflow steps.
# ABOUTME: Verifies list, create, and edit (by slug) flows end-to-end.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Mojo::JSON qw(encode_json);
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::ProgramType;

my $tdb = Test::Registry::DB->new;
my $dao = $tdb->db;

my $tenant = Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Type Mgmt Tenant',
    slug => 'type_mgmt',
});
$dao->db->query('SELECT clone_schema(?)', 'type_mgmt');
$dao = Registry::DAO->new(url => $tdb->uri, schema => 'type_mgmt');
my $db = $dao->db;

# Seed one existing program type so list has something to show.
Registry::DAO::ProgramType->create($db, {
    name   => 'After School',
    slug   => 'after-school',
    config => encode_json({ session_pattern => 'weekly' }),
});

# Build a workflow matching the YAML we'll ship.
my $workflow = Registry::DAO::Workflow->create($db, {
    name        => 'Program Type Management',
    slug        => 'program-type-management',
    description => 'Manage program types',
    first_step  => 'list-or-create',
});
$workflow->add_step($db, {
    slug        => 'list-or-create',
    description => 'List existing or start a new program type',
    class       => 'Registry::DAO::WorkflowSteps::ProgramTypeList',
});
$workflow->add_step($db, {
    slug        => 'type-details',
    description => 'Name, description, and configuration',
    class       => 'Registry::DAO::WorkflowSteps::ProgramTypeDetails',
});
$workflow->add_step($db, {
    slug        => 'complete',
    description => 'Done',
    class       => 'Registry::DAO::WorkflowStep',
});

subtest 'list step shows existing program types' => sub {
    require_ok 'Registry::DAO::WorkflowSteps::ProgramTypeList';

    my $step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id,
        slug        => 'list-or-create',
    });
    my $run = $workflow->new_run($db);

    my $data = $step->prepare_template_data($db, $run);
    ok($data->{program_types}, 'program_types returned');
    is(scalar @{$data->{program_types}}, 1, 'one existing type listed');
    is($data->{program_types}[0]->name, 'After School', 'correct type');
};

subtest 'list step Create New advances to type-details with no slug' => sub {
    my $step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id,
        slug        => 'list-or-create',
    });
    my $run = $workflow->new_run($db);

    my $result = $step->process($db, { action => 'new' }, $run);
    is($result->{next_step}, 'type-details', 'advances to type-details');
    ok(!$result->{editing_slug}, 'no editing_slug on new');
};

subtest 'list step Edit picks an existing type' => sub {
    my $step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id,
        slug        => 'list-or-create',
    });
    my $run = $workflow->new_run($db);

    my $result = $step->process($db, {
        action => 'edit', slug => 'after-school',
    }, $run);
    is($result->{next_step},    'type-details', 'advances to type-details');
    is($result->{editing_slug}, 'after-school', 'editing_slug carries through');
};

subtest 'list step rejects edit of unknown slug' => sub {
    my $step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id,
        slug        => 'list-or-create',
    });
    my $run = $workflow->new_run($db);

    my $result = $step->process($db, {
        action => 'edit', slug => 'does-not-exist',
    }, $run);
    ok($result->{stay}, 'stays on step when target is unknown');
    ok($result->{errors}, 'returns errors');
};

subtest 'details step creates a new program type' => sub {
    require_ok 'Registry::DAO::WorkflowSteps::ProgramTypeDetails';

    my $step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id,
        slug        => 'type-details',
    });
    my $run = $workflow->new_run($db);

    my $result = $step->process($db, {
        name            => 'Summer Camp',
        description     => 'Full-day summer programs',
        session_pattern => 'daily',
    }, $run);

    ok(!$result->{errors}, 'no validation errors') or diag(explain($result));
    is($result->{next_step}, 'complete', 'advances to complete');

    my $created = Registry::DAO::ProgramType->find_by_slug($db, 'summer-camp');
    ok($created, 'program type was created');
    is($created->name, 'Summer Camp', 'correct name');
    is($created->session_pattern, 'daily', 'config was stored');
};

subtest 'details step validates required fields' => sub {
    my $step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id,
        slug        => 'type-details',
    });
    my $run = $workflow->new_run($db);

    my $result = $step->process($db, { name => '' }, $run);
    ok($result->{errors}, 'returns validation errors');
    ok((grep /name/i, @{$result->{errors}}), 'error mentions name');
};

subtest 'details step edits an existing program type' => sub {
    my $step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id,
        slug        => 'type-details',
    });
    my $run = $workflow->new_run($db);
    $run->update_data($db, { editing_slug => 'after-school' });

    my $result = $step->process($db, {
        name            => 'After-School Renamed',
        description     => 'Updated description',
        session_pattern => 'weekly',
    }, $run);

    ok(!$result->{errors}, 'no errors on update') or diag(explain($result));
    is($result->{next_step}, 'complete', 'advances to complete');

    my $updated = Registry::DAO::ProgramType->find_by_slug($db, 'after-school');
    is($updated->name, 'After-School Renamed', 'name updated');
};

subtest 'details step pre-populates form when editing' => sub {
    my $step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id,
        slug        => 'type-details',
    });
    my $run = $workflow->new_run($db);
    $run->update_data($db, { editing_slug => 'summer-camp' });

    my $data = $step->prepare_template_data($db, $run);
    is($data->{name}, 'Summer Camp', 'name pre-filled');
    is($data->{session_pattern}, 'daily', 'config field pre-filled');
    ok($data->{editing}, 'editing flag set');
};

done_testing();
