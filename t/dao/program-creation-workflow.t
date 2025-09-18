#!/usr/bin/env perl
use v5.34.0;
use warnings;
use experimental 'signatures';
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::User;
use Registry::DAO::Project;
use Registry::DAO::ProgramType;
use Registry::DAO::WorkflowSteps::ProgramTypeSelection;
use Registry::DAO::WorkflowSteps::CurriculumDetails;
use Registry::DAO::WorkflowSteps::RequirementsAndPatterns;
use Registry::DAO::WorkflowSteps::ReviewAndCreate;
use Mojo::JSON qw(encode_json decode_json);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

# Create test tenant and set up schema
my $tenant = Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Test Program Creation Tenant',
    slug => 'test_program_creation',
});
$dao->db->query('SELECT clone_schema(?)', 'test_program_creation');

# Switch to tenant schema
$dao = Registry::DAO->new(url => $test_db->uri, schema => 'test_program_creation');
my $db = $dao->db;

# Create test program types
my $after_school_type = Registry::DAO::ProgramType->create($db, {
    name => 'After School Program',
    slug => 'after-school',
    config => encode_json({
        description => 'Traditional after-school enrichment programs',
        default_capacity => 15,
        session_pattern => 'weekly',
        duration_weeks => 10,
        standard_times => {
            'Weekday Afternoon' => {
                description => 'Monday-Friday 3:30-5:30 PM',
                pattern => 'weekdays',
                start_time => '15:30',
                end_time => '17:30'
            }
        },
        enrollment_rules => {
            same_session_for_siblings => 1
        }
    })
});

my $summer_camp_type = Registry::DAO::ProgramType->create($db, {
    name => 'Summer Camp',
    slug => 'summer-camp',
    config => encode_json({
        description => 'Full-day summer camp programs',
        default_capacity => 20,
        session_pattern => 'daily',
        duration_weeks => 8,
        standard_times => {
            'Full Day' => {
                description => 'Monday-Friday 8:00 AM - 4:00 PM',
                pattern => 'weekdays',
                start_time => '08:00',
                end_time => '16:00'
            }
        }
    })
});

# Create test user (Morgan persona)
my $morgan = Registry::DAO::User->create($db, {
    name => 'Morgan Developer',
    username => 'morgan_dev',
    email => 'morgan@example.com',
    user_type => 'staff',
    password => 'test123'
});

# Create workflow
my $workflow = Registry::DAO::Workflow->create($db, {
    name => 'Program Creation (Enhanced)',
    slug => 'program-creation-enhanced',
    description => 'Workflow for creating new educational programs',
    first_step => 'program-type-selection'
});

# Add workflow steps
$workflow->add_step($db, {
    slug => 'program-type-selection',
    description => 'Select Program Type'
});

$workflow->add_step($db, {
    slug => 'curriculum-details',
    description => 'Define Curriculum'
});

$workflow->add_step($db, {
    slug => 'requirements-and-patterns',
    description => 'Set Requirements and Schedule Patterns'
});

$workflow->add_step($db, {
    slug => 'review-and-create',
    description => 'Review and Create Program'
});

$workflow->add_step($db, {
    slug => 'complete',
    description => 'Program Created Successfully'
});

# Test basic workflow functionality
subtest 'Basic Workflow Test' => sub {
    # Just test that workflow was created correctly
    ok($workflow, 'Workflow created successfully');
    is($workflow->slug, 'program-creation-enhanced', 'Workflow has correct slug');
    is($workflow->name, 'Program Creation (Enhanced)', 'Workflow has correct name');

    # Test that we can create a run
    my $run = $workflow->new_run($db);
    ok($run, 'Can create workflow run');

    # Test basic workflow step existence
    my $first_step = $workflow->first_step($db);
    ok($first_step, 'First step exists');
    is($first_step->slug, 'program-type-selection', 'First step is program type selection');
};

# Test that workflow components exist
subtest 'Workflow Components Test' => sub {
    # Test that program types exist
    my $program_type_count = $db->query('SELECT COUNT(*) FROM program_types')->array->[0];
    is($program_type_count, 2, 'Both program types created');

    # Test that users exist
    my $user_count = $db->query('SELECT COUNT(*) FROM users')->array->[0];
    is($user_count, 1, 'Morgan user created');

    # Test basic data access
    my $after_school = Registry::DAO::ProgramType->find($db, { slug => 'after-school' });
    ok($after_school, 'After school program type can be loaded');
    is($after_school->name, 'After School Program', 'Program type has correct name');

    my $summer_camp = Registry::DAO::ProgramType->find($db, { slug => 'summer-camp' });
    ok($summer_camp, 'Summer camp program type can be loaded');
    is($summer_camp->name, 'Summer Camp', 'Program type has correct name');

    # Test that workflow steps were created
    my $step_count = $db->query('SELECT COUNT(*) FROM workflow_steps WHERE workflow_id = ?', $workflow->id)->array->[0];
    is($step_count, 5, 'All workflow steps created');
};

done_testing();