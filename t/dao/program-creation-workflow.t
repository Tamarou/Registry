#!/usr/bin/env perl
use v5.34.0;
use warnings;
use experimental 'signatures';

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Workflow;
use Registry::DAO::ProgramType;
use Registry::DAO::Project;
use Mojo::JSON qw(decode_json);

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db;

# Create test tenant and set search path
$db->query(q{
    INSERT INTO registry.tenants (id, name, slug, config, status)
    VALUES (1, 'Test Tenant', 'test-tenant', '{}', 'active')
});
$db->query("SET search_path TO tenant_1, registry, public");

# Create test program types
my $afterschool_type = Registry::DAO::ProgramType->new(
    name => 'Afterschool Program',
    slug => 'afterschool',
    config => {
        description => 'Regular afterschool programs',
        enrollment_rules => { same_session_for_siblings => 1 },
        standard_times => { default => '15:00' },
        session_pattern => 'weekly_for_x_weeks'
    }
)->save($db);

my $camp_type = Registry::DAO::ProgramType->new(
    name => 'Summer Camp',
    slug => 'summer-camp',
    config => {
        description => 'Summer camp programs',
        enrollment_rules => { same_session_for_siblings => 0 },
        session_pattern => 'daily_for_x_days'
    }
)->save($db);

# Create workflow
my $workflow = Registry::DAO::Workflow->new(
    name   => 'Test Program Creation',
    config => {
        steps => [
            { id => 'program-type-selection', type => 'custom', class => 'Registry::DAO::WorkflowSteps::ProgramTypeSelection' },
            { id => 'curriculum-details', type => 'custom', class => 'Registry::DAO::WorkflowSteps::CurriculumDetails' },
            { id => 'requirements-and-patterns', type => 'custom', class => 'Registry::DAO::WorkflowSteps::RequirementsAndPatterns' },
            { id => 'review-and-create', type => 'custom', class => 'Registry::DAO::WorkflowSteps::ReviewAndCreate' },
            { id => 'complete', type => 'form' }
        ]
    }
)->save($db);

subtest 'Program type selection' => sub {
    my $run = $workflow->start($db);
    
    # Test initial load
    my $result = $workflow->process_step($db, $run, 'program-type-selection', {});
    is $result->{next_step}, 'program-type-selection', 'Stays on selection step';
    ok $result->{data}->{program_types}, 'Program types loaded';
    is scalar(@{$result->{data}->{program_types}}), 2, 'Two program types available';
    
    # Test selection
    $result = $workflow->process_step($db, $run, 'program-type-selection', {
        program_type_id => $afterschool_type->id
    });
    is $result->{next_step}, 'curriculum-details', 'Moves to curriculum step';
    is $run->data->{program_type_id}, $afterschool_type->id, 'Program type ID stored';
    is $run->data->{program_type_name}, 'Afterschool Program', 'Program type name stored';
    
    # Test invalid selection
    $run = $workflow->start($db);
    $result = $workflow->process_step($db, $run, 'program-type-selection', {
        program_type_id => 'invalid-id'
    });
    is $result->{next_step}, 'program-type-selection', 'Stays on selection with invalid ID';
    ok $result->{errors}, 'Error returned for invalid selection';
};

subtest 'Curriculum details' => sub {
    my $run = $workflow->start($db);
    $run->data->{program_type_id} = $afterschool_type->id;
    $run->data->{program_type_name} = 'Afterschool Program';
    $run->save($db);
    
    # Test validation
    my $result = $workflow->process_step($db, $run, 'curriculum-details', {
        name => '',  # Missing required field
        description => 'Test'
    });
    is $result->{next_step}, 'curriculum-details', 'Stays on step with validation error';
    ok $result->{errors}, 'Validation errors returned';
    
    # Test successful submission
    $result = $workflow->process_step($db, $run, 'curriculum-details', {
        name => 'Math Enrichment Program',
        description => 'An afterschool program focused on advanced mathematics',
        learning_objectives => 'Students will master algebra concepts',
        skills_developed => 'Problem-solving, logical thinking',
        materials_needed => 'Workbooks, calculators'
    });
    
    is $result->{next_step}, 'requirements-and-patterns', 'Moves to requirements step';
    is $run->data->{curriculum}->{name}, 'Math Enrichment Program', 'Program name stored';
    ok $run->data->{curriculum}->{learning_objectives}, 'Learning objectives stored';
};

subtest 'Requirements and patterns' => sub {
    my $run = $workflow->start($db);
    $run->data->{program_type_id} = $afterschool_type->id;
    $run->data->{curriculum} = { name => 'Test Program' };
    $run->save($db);
    
    # Test age validation
    my $result = $workflow->process_step($db, $run, 'requirements-and-patterns', {
        min_age => 10,
        max_age => 8,  # Invalid: min > max
    });
    is $result->{next_step}, 'requirements-and-patterns', 'Stays on step with validation error';
    ok $result->{errors}, 'Age validation error returned';
    
    # Test successful submission
    $result = $workflow->process_step($db, $run, 'requirements-and-patterns', {
        min_age => 8,
        max_age => 12,
        min_grade => '3',
        max_grade => '6',
        staff_ratio => '1:12',
        staff_qualifications => 'Teaching credential preferred',
        pattern_type => 'weekly',
        duration_weeks => 10,
        sessions_per_week => 2,
        days_of_week => ['Tuesday', 'Thursday'],
        session_duration_minutes => 90,
        default_start_time => '15:30'
    });
    
    is $result->{next_step}, 'review-and-create', 'Moves to review step';
    is $run->data->{requirements}->{min_age}, 8, 'Min age stored';
    is $run->data->{requirements}->{staff_ratio}, '1:12', 'Staff ratio stored';
    is_deeply $run->data->{schedule_pattern}->{days_of_week}, ['Tuesday', 'Thursday'], 'Days stored';
};

subtest 'Review and create' => sub {
    my $run = $workflow->start($db);
    $run->data->{program_type_id} = $afterschool_type->id;
    $run->data->{curriculum} = {
        name => 'Math Enrichment',
        description => 'Advanced math program'
    };
    $run->data->{requirements} = {
        min_age => 8,
        max_age => 12,
        staff_ratio => '1:12'
    };
    $run->data->{schedule_pattern} = {
        type => 'weekly',
        duration_weeks => 10,
        days_of_week => ['Tuesday', 'Thursday']
    };
    $run->save($db);
    
    # Test edit action
    my $result = $workflow->process_step($db, $run, 'review-and-create', {
        action => 'edit',
        edit_step => 'curriculum-details'
    });
    is $result->{next_step}, 'curriculum-details', 'Returns to edit step';
    
    # Test create
    $result = $workflow->process_step($db, $run, 'review-and-create', {
        confirm => 1
    });
    is $result->{next_step}, 'complete', 'Moves to complete step';
    ok $run->data->{created_project_id}, 'Project ID stored';
    
    # Verify project was created
    my $project = Registry::DAO::Project->new(id => $run->data->{created_project_id})->load($db);
    ok $project, 'Project created in database';
    is $project->name, 'Math Enrichment', 'Project name matches';
    is $project->program_type_id, $afterschool_type->id, 'Program type ID set';
    
    # Check stored config
    my $config = decode_json($project->config);
    is $config->{curriculum}->{name}, 'Math Enrichment', 'Curriculum stored in config';
    is $config->{requirements}->{min_age}, 8, 'Requirements stored in config';
    is_deeply $config->{schedule_pattern}->{days_of_week}, ['Tuesday', 'Thursday'], 'Schedule stored';
};

done_testing();