#!/usr/bin/env perl
# ABOUTME: Smoke test for admin program setup workflows.
# ABOUTME: Exercises each workflow step's process() method end-to-end to find breakage.
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
use Registry::DAO::ProgramType;
use Registry::DAO::Location;
use Registry::DAO::Session;
use Registry::DAO::Event;
use Mojo::JSON qw(encode_json decode_json);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

# Create test tenant and set up schema
my $tenant = Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Smoke Test Tenant',
    slug => 'smoke_test_admin',
});
$dao->db->query('SELECT clone_schema(?)', 'smoke_test_admin');

# Switch to tenant schema
$dao = Registry::DAO->new(url => $test_db->uri, schema => 'smoke_test_admin');
my $db = $dao->db;

# -- Seed data ---------------------------------------------------------------

my $admin = Registry::DAO::User->create($db, {
    name     => 'Victoria Admin',
    username => 'victoria',
    email    => 'victoria@example.com',
    user_type => 'staff',
    password => 'test123',
});

my $program_type = Registry::DAO::ProgramType->create($db, {
    name   => 'After School Program',
    slug   => 'after-school',
    config => encode_json({
        description      => 'After-school enrichment',
        default_capacity => 15,
        session_pattern  => 'weekly',
    }),
});

my $location = Registry::DAO::Location->create($db, {
    name         => 'Dr Phillips Elementary',
    address_info => {
        street_address => '123 School Rd',
        city           => 'Orlando',
        state          => 'FL',
        postal_code    => '32819',
    },
    capacity => 20,
    metadata => {},
});

# -- 1. Program Creation Workflow ---------------------------------------------

subtest 'Program Creation: ProgramTypeSelection step' => sub {
    require Registry::DAO::WorkflowSteps::ProgramTypeSelection;

    my $workflow = Registry::DAO::Workflow->create($db, {
        name       => 'Program Creation Smoke',
        slug       => 'program_creation_smoke',
        description => 'Smoke test',
        first_step => 'program-type-selection',
    });

    $workflow->add_step($db, { slug => 'program-type-selection', description => 'Select type',
        class => 'Registry::DAO::WorkflowSteps::ProgramTypeSelection' });
    $workflow->add_step($db, { slug => 'curriculum-details', description => 'Curriculum',
        class => 'Registry::DAO::WorkflowSteps::CurriculumDetails' });
    $workflow->add_step($db, { slug => 'requirements-and-patterns', description => 'Requirements',
        class => 'Registry::DAO::WorkflowSteps::RequirementsAndPatterns' });
    $workflow->add_step($db, { slug => 'review-and-create', description => 'Review',
        class => 'Registry::DAO::WorkflowSteps::ReviewAndCreate' });
    $workflow->add_step($db, { slug => 'complete', description => 'Done',
        class => 'Registry::DAO::WorkflowStep' });

    my $run  = $workflow->new_run($db);
    my $step = Registry::DAO::WorkflowSteps::ProgramTypeSelection->find($db, {
        workflow_id => $workflow->id,
        slug        => 'program-type-selection',
    });
    ok($step, 'ProgramTypeSelection step found');

    # Test prepare_template_data
    my $template_data = eval { $step->prepare_template_data($db, $run) };
    ok(!$@, 'prepare_template_data does not crash') or diag("Error: $@");
    ok($template_data->{program_types}, 'template data includes program_types');

    # Test process with no selection (should stay)
    my $result = eval { $step->process($db, {}, $run) };
    ok(!$@, 'process with empty data does not crash') or diag("Error: $@");
    ok($result->{stay}, 'stays on step with no selection');

    # Test process with valid selection
    $result = eval { $step->process($db, { program_type_slug => 'after-school' }, $run) };
    ok(!$@, 'process with valid selection does not crash') or diag("Error: $@");
    is($result->{program_type_slug}, 'after-school', 'returns selected slug');

    # Merge result into run data for next steps
    $run->update_data($db, $result);
};

subtest 'Program Creation: CurriculumDetails step' => sub {
    require Registry::DAO::WorkflowSteps::CurriculumDetails;

    # Reuse the workflow from previous subtest by finding the run
    my $workflow = Registry::DAO::Workflow->find($db, { slug => 'program_creation_smoke' });
    my $run = $workflow->latest_run($db);
    my $step = Registry::DAO::WorkflowSteps::CurriculumDetails->find($db, {
        workflow_id => $workflow->id,
        slug        => 'curriculum-details',
    });
    ok($step, 'CurriculumDetails step found');

    # Test validation - missing required fields
    my $result = eval { $step->process($db, {}, $run) };
    ok(!$@, 'process with empty data does not crash') or diag("Error: $@");
    ok($result->{errors}, 'returns errors for missing fields');

    # Test with valid data
    $result = eval {
        $step->process($db, {
            name        => 'Art Adventures',
            description => 'A creative after-school art program',
            learning_objectives => 'Color theory, mixed media',
        }, $run);
    };
    ok(!$@, 'process with valid data does not crash') or diag("Error: $@");
    ok($result->{curriculum}, 'returns curriculum data');
    is($result->{curriculum}{name}, 'Art Adventures', 'curriculum name correct');

    $run->update_data($db, $result);
};

subtest 'Program Creation: RequirementsAndPatterns step' => sub {
    require Registry::DAO::WorkflowSteps::RequirementsAndPatterns;

    my $workflow = Registry::DAO::Workflow->find($db, { slug => 'program_creation_smoke' });
    my $run = $workflow->latest_run($db);
    my $step = Registry::DAO::WorkflowSteps::RequirementsAndPatterns->find($db, {
        workflow_id => $workflow->id,
        slug        => 'requirements-and-patterns',
    });
    ok($step, 'RequirementsAndPatterns step found');

    # Test with no data (should stay)
    my $result = eval { $step->process($db, {}, $run) };
    ok(!$@, 'process with empty data does not crash') or diag("Error: $@");
    ok($result->{stay}, 'stays when no min_age submitted');

    # Test with valid data
    $result = eval {
        $step->process($db, {
            min_age                  => 5,
            max_age                  => 12,
            min_grade                => 'K',
            max_grade                => '6',
            duration_weeks           => 10,
            sessions_per_week        => 2,
            session_duration_minutes => 90,
        }, $run);
    };
    ok(!$@, 'process with valid data does not crash') or diag("Error: $@");
    ok($result->{requirements}, 'returns requirements');
    ok($result->{schedule_pattern}, 'returns schedule_pattern');

    # Test validation - min > max age
    $result = eval { $step->process($db, { min_age => 12, max_age => 5 }, $run) };
    ok(!$@, 'process with invalid age range does not crash') or diag("Error: $@");
    ok($result->{errors}, 'returns errors for invalid age range');

    $run->update_data($db, {
        requirements     => $result->{requirements} // { min_age => 5, max_age => 12 },
        schedule_pattern => $result->{schedule_pattern} // { duration_weeks => 10 },
    });
};

subtest 'Program Creation: ReviewAndCreate step' => sub {
    require Registry::DAO::WorkflowSteps::ReviewAndCreate;

    my $workflow = Registry::DAO::Workflow->find($db, { slug => 'program_creation_smoke' });
    my $run = $workflow->latest_run($db);
    my $step = Registry::DAO::WorkflowSteps::ReviewAndCreate->find($db, {
        workflow_id => $workflow->id,
        slug        => 'review-and-create',
    });
    ok($step, 'ReviewAndCreate step found');

    # Test prepare_template_data
    my $template_data = eval { $step->prepare_template_data($db, $run) };
    ok(!$@, 'prepare_template_data does not crash') or diag("Error: $@");

    # Test without confirmation (should stay)
    my $result = eval { $step->process($db, {}, $run) };
    ok(!$@, 'process without confirm does not crash') or diag("Error: $@");
    ok($result->{stay}, 'stays without confirmation');

    # Test with confirmation - creates the project
    $result = eval { $step->process($db, { confirm => 1 }, $run) };
    ok(!$@, 'process with confirm does not crash') or diag("Error: $@");
    ok($result->{created_project_id}, 'project was created') or diag(explain($result));

    # Verify project exists in database
    if ($result->{created_project_id}) {
        my $project = Registry::DAO::Project->find($db, { id => $result->{created_project_id} });
        ok($project, 'project exists in database');
        is($project->name, 'Art Adventures', 'project has correct name');
    }
};

# -- 2. Program Location Assignment Workflow ----------------------------------

subtest 'Location Assignment: SelectProgram step' => sub {
    require Registry::DAO::WorkflowSteps::SelectProgram;

    my $workflow = Registry::DAO::Workflow->create($db, {
        name        => 'Location Assignment Smoke',
        slug        => 'location_assignment_smoke',
        description => 'Smoke test',
        first_step  => 'select-program',
    });

    $workflow->add_step($db, { slug => 'select-program', description => 'Select program',
        class => 'Registry::DAO::WorkflowSteps::SelectProgram' });
    $workflow->add_step($db, { slug => 'choose-locations', description => 'Choose locations',
        class => 'Registry::DAO::WorkflowSteps::ChooseLocations' });
    $workflow->add_step($db, { slug => 'configure-location', description => 'Configure',
        class => 'Registry::DAO::WorkflowSteps::ConfigureLocation' });
    $workflow->add_step($db, { slug => 'generate-events', description => 'Generate',
        class => 'Registry::DAO::WorkflowSteps::GenerateEvents' });
    $workflow->add_step($db, { slug => 'complete', description => 'Done',
        class => 'Registry::DAO::WorkflowStep' });

    my $run  = $workflow->new_run($db);
    my $step = Registry::DAO::WorkflowSteps::SelectProgram->find($db, {
        workflow_id => $workflow->id,
        slug        => 'select-program',
    });
    ok($step, 'SelectProgram step found');

    # Test prepare_data - calls Project->list() which may not exist
    my $data = eval { $step->prepare_data($db) };
    ok(!$@, 'prepare_data does not crash (Project->list)') or diag("Error: $@");

    # Create a project directly for this test in case ReviewAndCreate failed
    my $project = Registry::DAO::Project->find($db, { name => 'Art Adventures' });
    unless ($project) {
        $project = Registry::DAO::Project->create($db, {
            name              => 'Smoke Test Program',
            program_type_slug => 'after-school',
            notes             => 'Created for smoke test',
        });
    }
    ok($project, 'test project exists');

    # Test process with project selection - calls Project->new(...)->load()
    my $result = eval { $step->process($db, { project_id => $project->id }, $run) };
    ok(!$@, 'process with project_id does not crash (Project->load)') or diag("Error: $@");

    if ($result && !$@) {
        is($result->{next_step}, 'choose-locations', 'advances to choose-locations');
    }
};

subtest 'Location Assignment: ChooseLocations step' => sub {
    require Registry::DAO::WorkflowSteps::ChooseLocations;

    my $workflow = Registry::DAO::Workflow->find($db, { slug => 'location_assignment_smoke' });
    my $run  = $workflow->latest_run($db);
    my $step = Registry::DAO::WorkflowSteps::ChooseLocations->find($db, {
        workflow_id => $workflow->id,
        slug        => 'choose-locations',
    });
    ok($step, 'ChooseLocations step found');

    # Test prepare_data - calls Location->list() which does not exist
    my $data = eval { $step->prepare_data($db) };
    ok(!$@, 'prepare_data does not crash (Location->list)') or diag("Error: $@");

    # Test process with location selection - calls Location->new(...)->load()
    my $result = eval {
        $step->process($db, { location_ids => [$location->id] }, $run);
    };
    ok(!$@, 'process with location_ids does not crash (Location->load)') or diag("Error: $@");

    if (!$@) {
        is($result->{next_step}, 'configure-location', 'advances to configure-location');
    }
};

subtest 'Location Assignment: ConfigureLocation step' => sub {
    require Registry::DAO::WorkflowSteps::ConfigureLocation;

    my $workflow = Registry::DAO::Workflow->find($db, { slug => 'location_assignment_smoke' });
    my $run  = $workflow->latest_run($db);
    my $step = Registry::DAO::WorkflowSteps::ConfigureLocation->find($db, {
        workflow_id => $workflow->id,
        slug        => 'configure-location',
    });
    ok($step, 'ConfigureLocation step found');

    # Ensure run data has selected_locations from previous step
    my $selected = $run->data->{selected_locations};
    unless ($selected && @$selected) {
        fail('run has selected_locations data - previous step failed');
        return;
    }
    pass('run has selected_locations data');

    my $location_id = $selected->[0]{id};

    # Test process with configuration
    my $result = eval {
        $step->process($db, {
            location_configs => {
                $location_id => {
                    capacity => 20,
                    schedule => { tuesday => '15:30', thursday => '15:30' },
                    notes    => 'Main art room',
                },
            },
        }, $run);
    };
    ok(!$@, 'process with config does not crash') or diag("Error: $@");

    if (!$@) {
        is($result->{next_step}, 'generate-events', 'advances to generate-events');
    }
};

subtest 'Location Assignment: GenerateEvents step' => sub {
    require Registry::DAO::WorkflowSteps::GenerateEvents;

    my $workflow = Registry::DAO::Workflow->find($db, { slug => 'location_assignment_smoke' });
    my $run  = $workflow->latest_run($db);
    my $step = Registry::DAO::WorkflowSteps::GenerateEvents->find($db, {
        workflow_id => $workflow->id,
        slug        => 'generate-events',
    });
    ok($step, 'GenerateEvents step found');

    # Ensure run data has configured_locations
    my $configured = $run->data->{configured_locations};
    unless ($configured && @$configured) {
        fail('run has configured_locations data - previous step failed');
        return;
    }
    pass('run has configured_locations data');

    # Test prepare_data
    my $data = eval { $step->prepare_data($db) };
    ok(!$@, 'prepare_data does not crash') or diag("Error: $@");

    # Test event generation
    my $start_epoch = time() + 86400 * 7; # one week from now
    my $result = eval {
        $step->process($db, {
            confirm_generation   => 1,
            generation_params    => {
                start_date     => $start_epoch,
                duration_weeks => 4,
            },
        }, $run);
    };
    ok(!$@, 'process with generation params does not crash') or diag("Error: $@");

    if ($result && $result->{next_step}) {
        is($result->{next_step}, 'complete', 'advances to complete');
    }
    elsif ($result && $result->{errors}) {
        diag("Generation errors: @{$result->{errors}}");
    }
};

# -- 3. Pricing Plan Creation Workflow ----------------------------------------

subtest 'Pricing: PricingPlanBasics step' => sub {
    require Registry::DAO::WorkflowSteps::PricingPlanBasics;
    require Registry::DAO::PricingPlan;

    my $workflow = Registry::DAO::Workflow->create($db, {
        name        => 'Pricing Smoke',
        slug        => 'pricing_smoke',
        description => 'Smoke test',
        first_step  => 'plan-basics',
    });

    $workflow->add_step($db, { slug => 'plan-basics', description => 'Plan basics',
        class => 'Registry::DAO::WorkflowSteps::PricingPlanBasics' });
    $workflow->add_step($db, { slug => 'pricing-model', description => 'Pricing model',
        class => 'Registry::DAO::WorkflowStep' });
    $workflow->add_step($db, { slug => 'resource-allocation', description => 'Resources',
        class => 'Registry::DAO::WorkflowStep' });
    $workflow->add_step($db, { slug => 'requirements-rules', description => 'Rules',
        class => 'Registry::DAO::WorkflowStep' });
    $workflow->add_step($db, { slug => 'review-activate', description => 'Review',
        class => 'Registry::DAO::WorkflowStep' });

    my $run  = $workflow->new_run($db);
    my $step = Registry::DAO::WorkflowSteps::PricingPlanBasics->find($db, {
        workflow_id => $workflow->id,
        slug        => 'plan-basics',
    });
    ok($step, 'PricingPlanBasics step found');

    # Test prepare_template_data
    my $template_data = eval { $step->prepare_template_data($db, $run) };
    ok(!$@, 'prepare_template_data does not crash') or diag("Error: $@");
    ok($template_data->{plan_types}, 'returns plan_types');

    # Test validation - missing required fields
    my $result = eval { $step->process($db, {}, $run) };
    ok(!$@, 'process with empty data does not crash') or diag("Error: $@");
    ok($result->{stay}, 'stays on step with missing fields');
    ok($result->{errors}, 'returns validation errors');

    # Test with valid data
    $result = eval {
        $step->process($db, {
            plan_name        => 'After School Standard',
            plan_description => 'Standard pricing for after school programs',
            plan_type        => 'one_time',
            target_audience  => 'individual',
            plan_scope       => 'customer',
        }, $run);
    };
    ok(!$@, 'process with valid data does not crash') or diag("Error: $@");

    if ($result && !$result->{stay}) {
        ok($result->{next_step}, 'advances to next step');
    }
    else {
        diag('PricingPlanBasics did not advance: ' . explain($result));
    }
};

# -- 4. Session Creation Workflow (old-style) ---------------------------------

subtest 'Session Creation: CreateSession step' => sub {
    require Registry::DAO::WorkflowSteps::CreateSession;

    ok(Registry::DAO::WorkflowSteps::CreateSession->isa('Registry::DAO::WorkflowStep'),
       'CreateSession inherits from WorkflowStep');
    can_ok('Registry::DAO::WorkflowSteps::CreateSession', 'process');
};

# -- 5. Event Creation Workflow (old-style) -----------------------------------

subtest 'Event Creation: CreateEvent step' => sub {
    require Registry::DAO::WorkflowSteps::CreateEvent;

    ok(Registry::DAO::WorkflowSteps::CreateEvent->isa('Registry::DAO::WorkflowStep'),
       'CreateEvent inherits from WorkflowStep');
    can_ok('Registry::DAO::WorkflowSteps::CreateEvent', 'process');
};

# -- 6. Method existence checks -----------------------------------------------

subtest 'DAO method existence checks' => sub {
    # Methods called by workflow steps that may not exist
    ok(Registry::DAO::Project->can('find'),   'Project->find exists');
    ok(Registry::DAO::Location->can('find'),  'Location->find exists');

    # These are called by workflow steps but may not exist on base Object
    my $has_project_list  = Registry::DAO::Project->can('list');
    my $has_location_list = Registry::DAO::Location->can('list');

    ok($has_project_list,  'Project->list exists')
        or diag('MISSING: SelectProgram calls Project->list() but it does not exist');
    ok($has_location_list, 'Location->list exists')
        or diag('MISSING: ChooseLocations calls Location->list() but it does not exist');

    # SelectProgram and ChooseLocations call ->new(id => $id)->load($db)
    # but Object base class has no load() method
    my $has_project_load  = Registry::DAO::Project->can('load');
    my $has_location_load = Registry::DAO::Location->can('load');

    ok($has_project_load,  'Project->load exists')
        or diag('MISSING: SelectProgram calls Project->new(id => $id)->load($db)');
    ok($has_location_load, 'Location->load exists')
        or diag('MISSING: ChooseLocations calls Location->new(id => $id)->load($db)');

    # SelectProgram stores $project->description but Project has no description method
    my $has_project_desc = Registry::DAO::Project->can('description');
    ok($has_project_desc, 'Project->description exists')
        or diag('MISSING: SelectProgram stores $project->description but Project has notes, not description');

    # GenerateEvents calls $session->project_id but Session has no project_id accessor
    my $has_session_project_id = Registry::DAO::Session->can('project_id');
    ok($has_session_project_id, 'Session->project_id exists')
        or diag('MISSING: GenerateEvents line 131 calls $session->project_id but Session has no such accessor');

    # PricingPlan needs to be findable by plan_name
    require Registry::DAO::PricingPlan;
    ok(Registry::DAO::PricingPlan->can('find'), 'PricingPlan->find exists');
};

done_testing();
