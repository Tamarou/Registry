#!/usr/bin/env perl
use v5.34.0;
use warnings;
use experimental 'signatures';
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Workflow;
use Registry::DAO::User;
use Registry::DAO::Project;
use Registry::DAO::Location;
use Registry::DAO::Session;
use Registry::DAO::Event;
use Registry::DAO::ProgramType;
use Registry::WorkflowProcessor;
use Mojo::JSON qw(encode_json decode_json);
use DateTime;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

# Create test tenant and set up schema
my $tenant = Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Test Morgan Integration Tenant',
    slug => 'test_morgan_integration',
});
$dao->db->query('SELECT clone_schema(?)', 'test_morgan_integration');

# Switch to tenant schema
$dao = Registry::DAO->new(url => $test_db->uri, schema => 'test_morgan_integration');
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

# Create test locations
my $location1 = Registry::DAO::Location->create($db, {
    name => 'Main Campus',
    address_info => {
        street_address => '100 Education Blvd',
        city => 'Learning City',
        state => 'TS',
        postal_code => '12345'
    },
    capacity => 30,
    metadata => encode_json({
        facilities => ['Computer lab', 'Science lab', 'Library']
    })
});

my $location2 = Registry::DAO::Location->create($db, {
    name => 'Community Center',
    address_info => {
        street_address => '200 Community St',
        city => 'Neighborhood',
        state => 'TS',
        postal_code => '12346'
    },
    capacity => 20,
    metadata => encode_json({
        facilities => ['Meeting rooms', 'Kitchen', 'Playground']
    })
});

# Create test teacher
my $teacher = Registry::DAO::User->create($db, {
    name => 'Alice Teacher',
    username => 'alice_teacher',
    first_name => 'Alice',
    last_name => 'Teacher',
    email => 'alice@example.com',
    user_type => 'staff',
    password => 'test123'
});

# Create Morgan user (Program Developer persona)
my $morgan = Registry::DAO::User->create($db, {
    name => 'Morgan Developer',
    username => 'morgan_developer',
    first_name => 'Morgan',
    last_name => 'Developer',
    email => 'morgan@example.com',
    user_type => 'staff',
    password => 'test123'
});

# Create Program Creation workflow
my $creation_workflow = Registry::DAO::Workflow->create($db, {
    name => 'Program Creation (Enhanced)',
    slug => 'program-creation-enhanced',
    description => 'Workflow for creating new educational programs',
    first_step => 'program-type-selection',
    steps => encode_json([
        {
            slug => 'program-type-selection',
            description => 'Select Program Type',
            template => 'program-creation/program-type-selection',
            class => 'Registry::DAO::WorkflowSteps::ProgramTypeSelection'
        },
        {
            slug => 'curriculum-details',
            description => 'Define Curriculum',
            template => 'program-creation/curriculum-details',
            class => 'Registry::DAO::WorkflowSteps::CurriculumDetails'
        },
        {
            slug => 'requirements-and-patterns',
            description => 'Set Requirements and Schedule Patterns',
            template => 'program-creation/requirements-and-patterns',
            class => 'Registry::DAO::WorkflowSteps::RequirementsAndPatterns'
        },
        {
            slug => 'review-and-create',
            description => 'Review and Create Program',
            template => 'program-creation/review-and-create',
            class => 'Registry::DAO::WorkflowSteps::ReviewAndCreate'
        },
        {
            slug => 'complete',
            description => 'Program Created Successfully',
            template => 'program-creation/complete',
            class => 'Registry::DAO::WorkflowStep'
        }
    ])
});

# Create Program Location Assignment workflow
my $assignment_workflow = Registry::DAO::Workflow->create($db, {
    name => 'Program Location Assignment',
    slug => 'program-location-assignment',
    description => 'Workflow for assigning programs to locations and generating events',
    first_step => 'select-program',
    steps => encode_json([
        {
            slug => 'select-program',
            description => 'Select Existing Program',
            template => 'program-location-assignment/select-program',
            class => 'Registry::DAO::WorkflowSteps::SelectProgram'
        },
        {
            slug => 'choose-locations',
            description => 'Choose Locations',
            template => 'program-location-assignment/choose-locations',
            class => 'Registry::DAO::WorkflowSteps::ChooseLocations'
        },
        {
            slug => 'configure-location',
            description => 'Configure Per-Location Details',
            template => 'program-location-assignment/configure-location',
            class => 'Registry::DAO::WorkflowSteps::ConfigureLocation'
        },
        {
            slug => 'generate-events',
            description => 'Generate Events',
            template => 'program-location-assignment/generate-events',
            class => 'Registry::DAO::WorkflowSteps::GenerateEvents'
        },
        {
            slug => 'complete',
            description => 'Program Assignment Complete',
            template => 'program-location-assignment/complete',
            class => 'Registry::DAO::WorkflowStep'
        }
    ])
});

# Test complete Morgan persona workflow: Create Program → Assign to Locations
subtest 'Complete Morgan Persona Integration Test' => sub {
    my $processor = Registry::WorkflowProcessor->new();

    # PHASE 1: CREATE NEW PROGRAM
    my $creation_run = $creation_workflow->create_run($db);

    # Step 1: Select program type
    my $result = $processor->process_step($db, $creation_workflow->id, $creation_run->id,
        'program-type-selection', {
            program_type_id => $after_school_type->id
        });
    is($result->{next_step}, 'curriculum-details', 'Creation: Program type selected');

    # Step 2: Define curriculum
    $result = $processor->process_step($db, $creation_workflow->id, $creation_run->id,
        'curriculum-details', {
            program_name => 'Advanced STEM Workshop',
            program_description => 'Hands-on science, technology, engineering, and math activities',
            learning_objectives => [
                'Scientific method application',
                'Basic programming concepts',
                'Engineering design process',
                'Mathematical problem solving'
            ],
            materials_needed => [
                'Laptops or tablets',
                'Science experiment kits',
                'Building materials (LEGO, etc.)',
                'Calculators'
            ],
            curriculum_notes => 'Designed for curious minds who love hands-on learning'
        });
    is($result->{next_step}, 'requirements-and-patterns', 'Creation: Curriculum defined');

    # Step 3: Set requirements and patterns
    $result = $processor->process_step($db, $creation_workflow->id, $creation_run->id,
        'requirements-and-patterns', {
            age_min => 10,
            age_max => 14,
            prerequisites => 'Interest in science and math',
            staff_requirements => '1 instructor per 12 students, science background preferred',
            safety_notes => 'Adult supervision required for all experiments',
            schedule_pattern => 'weekly',
            session_duration => 120
        });
    is($result->{next_step}, 'review-and-create', 'Creation: Requirements set');

    # Step 4: Review and create program
    my $initial_program_count = $db->query('SELECT COUNT(*) FROM projects')->array->[0];

    $result = $processor->process_step($db, $creation_workflow->id, $creation_run->id,
        'review-and-create', {
            confirm_create => 1
        });
    is($result->{next_step}, 'complete', 'Creation: Program created');

    my $final_program_count = $db->query('SELECT COUNT(*) FROM projects')->array->[0];
    is($final_program_count, $initial_program_count + 1, 'Creation: New program in database');

    # Verify the created program
    my $created_program = Registry::DAO::Project->new(name => 'Advanced STEM Workshop')->load($db);
    ok($created_program, 'Creation: Program can be loaded');
    is($created_program->program_type_slug, 'after-school', 'Creation: Correct program type');

    my $metadata = decode_json($created_program->metadata);
    is($metadata->{age_min}, 10, 'Creation: Age minimum stored');
    is($metadata->{age_max}, 14, 'Creation: Age maximum stored');
    ok($metadata->{learning_objectives}, 'Creation: Learning objectives stored');

    # PHASE 2: ASSIGN PROGRAM TO LOCATIONS
    my $assignment_run = $assignment_workflow->create_run($db);

    # Step 1: Select the program we just created
    $result = $processor->process_step($db, $assignment_workflow->id, $assignment_run->id,
        'select-program', {
            project_id => $created_program->id
        });
    is($result->{next_step}, 'choose-locations', 'Assignment: Program selected');

    # Step 2: Choose both locations
    $result = $processor->process_step($db, $assignment_workflow->id, $assignment_run->id,
        'choose-locations', {
            location_ids => [$location1->id, $location2->id]
        });
    is($result->{next_step}, 'configure-location', 'Assignment: Locations chosen');

    # Step 3: Configure each location
    $result = $processor->process_step($db, $assignment_workflow->id, $assignment_run->id,
        'configure-location', {
            location_configs => {
                $location1->id => {
                    capacity => 24,  # Main campus can handle more
                    schedule => 'Weekday Afternoon',
                    notes => 'Main campus with full lab facilities'
                },
                $location2->id => {
                    capacity => 16,  # Community center has less space
                    schedule => 'Weekday Afternoon',
                    pricing_override => 95.00,  # Slightly different pricing
                    notes => 'Community location, bring portable equipment'
                }
            }
        });
    is($result->{next_step}, 'generate-events', 'Assignment: Locations configured');

    # Step 4: Generate events with teacher assignment
    my $initial_sessions = $db->query('SELECT COUNT(*) FROM sessions')->array->[0];
    my $initial_events = $db->query('SELECT COUNT(*) FROM events')->array->[0];

    my $start_date = DateTime->now->add(days => 10)->ymd;
    $result = $processor->process_step($db, $assignment_workflow->id, $assignment_run->id,
        'generate-events', {
            confirm_generation => 1,
            generation_params => {
                start_date => $start_date,
                duration_weeks => 8
            },
            teacher_assignments => {
                $location1->id => $teacher->id  # Assign teacher to main campus
                # Leave community center without teacher for now
            }
        });
    is($result->{next_step}, 'complete', 'Assignment: Events generated');

    # Verify sessions were created
    my $final_sessions = $db->query('SELECT COUNT(*) FROM sessions')->array->[0];
    is($final_sessions, $initial_sessions + 2, 'Assignment: Two sessions created');

    # Verify events were created
    my $final_events = $db->query('SELECT COUNT(*) FROM events')->array->[0];
    ok($final_events > $initial_events, 'Assignment: Events created for sessions');

    # Verify session details
    my $sessions = $db->query('
        SELECT s.*, l.name as location_name
        FROM sessions s
        JOIN locations l ON s.location_id = l.id
        WHERE s.project_id = ?
        ORDER BY l.name
    ', $created_program->id)->hashes;

    is(scalar(@$sessions), 2, 'Assignment: Correct number of sessions');

    my $main_session = $sessions->[1];  # Main Campus (alphabetically second)
    is($main_session->{location_name}, 'Main Campus', 'Assignment: Main campus session exists');
    is($main_session->{capacity}, 24, 'Assignment: Main campus has correct capacity');

    my $community_session = $sessions->[0];  # Community Center (alphabetically first)
    is($community_session->{location_name}, 'Community Center', 'Assignment: Community session exists');
    is($community_session->{capacity}, 16, 'Assignment: Community center has correct capacity');

    # Verify teacher assignment
    my $teacher_assignments = $db->query('
        SELECT st.*, s.location_id, u.name as teacher_name
        FROM session_teachers st
        JOIN sessions s ON st.session_id = s.id
        JOIN users u ON st.user_id = u.id
        WHERE s.project_id = ?
    ', $created_program->id)->hashes;

    is(scalar(@$teacher_assignments), 1, 'Assignment: One teacher assignment created');
    is($teacher_assignments->[0]->{teacher_name}, 'Alice Teacher', 'Assignment: Correct teacher assigned');

    # Verify events span the correct duration
    my $event_count = $db->query('
        SELECT COUNT(*)
        FROM events e
        JOIN sessions s ON e.session_id = s.id
        WHERE s.project_id = ?
    ', $created_program->id)->array->[0];
    ok($event_count >= 16, 'Assignment: Sufficient events created (8 weeks × 2 locations)');
};

# Test Morgan's bulk operations capability
subtest 'Morgan Bulk Operations Test' => sub {
    my $processor = Registry::WorkflowProcessor->new();

    # Create a summer camp program first
    my $creation_run = $creation_workflow->create_run($db);

    # Quick program creation for summer camp
    $processor->process_step($db, $creation_workflow->id, $creation_run->id,
        'program-type-selection', { program_type_id => $summer_camp_type->id });

    $processor->process_step($db, $creation_workflow->id, $creation_run->id,
        'curriculum-details', {
            program_name => 'Creative Summer Adventures',
            program_description => 'Full-day summer camp with arts, sports, and outdoor activities',
            learning_objectives => ['Creativity', 'Teamwork', 'Outdoor skills'],
            materials_needed => ['Art supplies', 'Sports equipment', 'Outdoor gear']
        });

    $processor->process_step($db, $creation_workflow->id, $creation_run->id,
        'requirements-and-patterns', {
            age_min => 6,
            age_max => 12,
            schedule_pattern => 'daily',
            session_duration => 480  # 8 hours
        });

    $processor->process_step($db, $creation_workflow->id, $creation_run->id,
        'review-and-create', { confirm_create => 1 });

    my $summer_program = Registry::DAO::Project->new(name => 'Creative Summer Adventures')->load($db);
    ok($summer_program, 'Bulk: Summer program created');

    # Now assign to multiple locations with different configurations
    my $assignment_run = $assignment_workflow->create_run($db);

    $processor->process_step($db, $assignment_workflow->id, $assignment_run->id,
        'select-program', { project_id => $summer_program->id });

    $processor->process_step($db, $assignment_workflow->id, $assignment_run->id,
        'choose-locations', { location_ids => [$location1->id, $location2->id] });

    $processor->process_step($db, $assignment_workflow->id, $assignment_run->id,
        'configure-location', {
            location_configs => {
                $location1->id => {
                    capacity => 25,
                    schedule => 'Full Day',
                    notes => 'Main campus with full facilities and outdoor space'
                },
                $location2->id => {
                    capacity => 18,
                    schedule => 'Full Day',
                    pricing_override => 185.00,  # Premium pricing for community center
                    notes => 'Community center location'
                }
            }
        });

    my $initial_summer_sessions = $db->query('SELECT COUNT(*) FROM sessions WHERE project_id = ?', $summer_program->id)->array->[0];

    my $start_date = DateTime->now->add(days => 20)->ymd;
    $processor->process_step($db, $assignment_workflow->id, $assignment_run->id,
        'generate-events', {
            confirm_generation => 1,
            generation_params => {
                start_date => $start_date,
                duration_weeks => 6
            }
        });

    my $final_summer_sessions = $db->query('SELECT COUNT(*) FROM sessions WHERE project_id = ?', $summer_program->id)->array->[0];
    is($final_summer_sessions, $initial_summer_sessions + 2, 'Bulk: Summer camp sessions created');

    # Verify that both program types are working with different configurations
    my $all_programs = $db->query('SELECT name, program_type_slug FROM projects ORDER BY name')->hashes;
    is(scalar(@$all_programs), 2, 'Bulk: Two programs total');

    my ($stem_program) = grep { $_->{name} eq 'Advanced STEM Workshop' } @$all_programs;
    my ($camp_program) = grep { $_->{name} eq 'Creative Summer Adventures' } @$all_programs;

    is($stem_program->{program_type_slug}, 'after-school', 'Bulk: STEM program has correct type');
    is($camp_program->{program_type_slug}, 'summer-camp', 'Bulk: Camp program has correct type');

    # Verify sessions have different patterns based on program type
    my $all_sessions = $db->query('
        SELECT s.*, p.name as program_name, p.program_type_slug
        FROM sessions s
        JOIN projects p ON s.project_id = p.id
        ORDER BY p.name, s.location_id
    ')->hashes;

    is(scalar(@$all_sessions), 4, 'Bulk: Total of 4 sessions across both programs');

    # Count sessions per program type
    my @stem_sessions = grep { $_->{program_type_slug} eq 'after-school' } @$all_sessions;
    my @camp_sessions = grep { $_->{program_type_slug} eq 'summer-camp' } @$all_sessions;

    is(scalar(@stem_sessions), 2, 'Bulk: Two STEM sessions');
    is(scalar(@camp_sessions), 2, 'Bulk: Two camp sessions');
};

# Test error handling across workflows
subtest 'Cross-Workflow Error Handling' => sub {
    my $processor = Registry::WorkflowProcessor->new();

    # Test trying to assign a non-existent program
    my $assignment_run = $assignment_workflow->create_run($db);

    my $result = $processor->process_step($db, $assignment_workflow->id, $assignment_run->id,
        'select-program', { project_id => 99999 });

    is($result->{next_step}, 'select-program', 'Error: Invalid program ID handled');
    ok($result->{errors}, 'Error: Error message provided');

    # Test creating duplicate program name
    my $creation_run = $creation_workflow->create_run($db);

    # Go through creation steps but use existing name
    $processor->process_step($db, $creation_workflow->id, $creation_run->id,
        'program-type-selection', { program_type_id => $after_school_type->id });

    $processor->process_step($db, $creation_workflow->id, $creation_run->id,
        'curriculum-details', {
            program_name => 'Advanced STEM Workshop',  # This already exists
            program_description => 'Duplicate program test'
        });

    $processor->process_step($db, $creation_workflow->id, $creation_run->id,
        'requirements-and-patterns', {
            age_min => 8,
            age_max => 12,
            schedule_pattern => 'weekly'
        });

    $result = $processor->process_step($db, $creation_workflow->id, $creation_run->id,
        'review-and-create', { confirm_create => 1 });

    is($result->{next_step}, 'review-and-create', 'Error: Duplicate name handled');
    ok($result->{errors}, 'Error: Duplicate name error provided');
    like($result->{errors}->[0], qr/already exists/i, 'Error: Appropriate error message');
};

done_testing();