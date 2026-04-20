#!/usr/bin/env perl
# ABOUTME: DAO-level tests for the program-setup orchestrator workflow.
# ABOUTME: The single 'overview' step summarises what's been set up so far.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::ProgramType;
use Registry::DAO::Project;
use Registry::DAO::Location;
use Registry::DAO::User;
use Mojo::JSON qw(encode_json);

my $tdb = Test::Registry::DB->new;
my $dao = $tdb->db;

my $tenant = Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Orchestrator Tenant',
    slug => 'orchestrator',
});
$dao->db->query('SELECT clone_schema(?)', 'orchestrator');
$dao = Registry::DAO->new(url => $tdb->uri, schema => 'orchestrator');
my $db = $dao->db;

# Build a minimal workflow matching what we'll ship.
my $workflow = Registry::DAO::Workflow->create($db, {
    name        => 'Program Setup',
    slug        => 'program-setup',
    description => 'Orchestrator',
    first_step  => 'overview',
});
$workflow->add_step($db, {
    slug        => 'overview',
    description => 'Setup checklist with callcc buttons',
    class       => 'Registry::DAO::WorkflowSteps::ProgramSetupOverview',
});

subtest 'overview reports empty state when nothing is set up' => sub {
    require_ok 'Registry::DAO::WorkflowSteps::ProgramSetupOverview';

    my $step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id, slug => 'overview',
    });
    my $run  = $workflow->new_run($db);

    my $data = $step->prepare_template_data($db, $run);
    ok(defined $data->{checklist}, 'checklist returned');
    is(scalar @{$data->{checklist}}, 5, 'five checklist items');

    my %by_key = map { $_->{key} => $_ } @{$data->{checklist}};

    for my $key (qw(program_types locations programs sessions pricing)) {
        ok($by_key{$key}, "has $key item");
        is($by_key{$key}{status}, 'todo', "$key starts todo");
    }
};

subtest 'overview reports done when pieces exist' => sub {
    # Seed the pieces.
    Registry::DAO::ProgramType->create($db, {
        name => 'After School', slug => 'after-school',
        config => encode_json({}),
    });

    my $user = Registry::DAO::User->create($db, {
        name => 'Admin', username => 'admin_orch',
        email => 'admin@orch.local', user_type => 'staff', password => 'x',
    });
    Registry::DAO::Location->create($db, {
        name => 'Test Loc', address_info => {}, capacity => 10,
        contact_person_id => $user->id,
    });

    Registry::DAO::Project->create($db, {
        name => 'Art Program', slug => 'art-program',
        program_type_slug => 'after-school',
    });

    my $step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id, slug => 'overview',
    });
    my $run  = $workflow->new_run($db);

    my $data = $step->prepare_template_data($db, $run);
    my %by_key = map { $_->{key} => $_ } @{$data->{checklist}};

    is($by_key{program_types}{status}, 'done', 'program_types marked done');
    is($by_key{locations}{status},     'done', 'locations marked done');
    is($by_key{programs}{status},      'done', 'programs marked done');
    is($by_key{sessions}{status},      'todo', 'sessions still todo');
    is($by_key{pricing}{status},       'todo', 'pricing still todo');
};

subtest 'overview process stays on page' => sub {
    # The overview step is read-only; all transitions happen via callcc
    # into sub-workflows.
    my $step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id, slug => 'overview',
    });
    my $run  = $workflow->new_run($db);

    my $result = $step->process($db, {}, $run);
    ok($result->{stay}, 'stays on the overview step');
};

subtest 'each checklist item exposes a callcc target' => sub {
    my $step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id, slug => 'overview',
    });
    my $run = $workflow->new_run($db);

    my $data = $step->prepare_template_data($db, $run);
    for my $item (@{$data->{checklist}}) {
        ok($item->{callcc_target},
           "item '$item->{key}' has a callcc_target workflow slug");
        ok($item->{label}, "item '$item->{key}' has a label");
    }
};

done_testing();
