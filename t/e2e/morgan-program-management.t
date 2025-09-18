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
use Registry::DAO::Enrollment;
use Registry::DAO::Family;
use Registry::WorkflowProcessor;
use Mojo::JSON qw(encode_json decode_json);
use DateTime;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

# Create test tenant and set up schema
my $tenant = Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Test Morgan E2E Tenant',
    slug => 'test_morgan_e2e',
});
$dao->db->query('SELECT clone_schema(?)', 'test_morgan_e2e');

# Switch to tenant schema
$dao = Registry::DAO->new(url => $test_db->uri, schema => 'test_morgan_e2e');
my $db = $dao->db;

# Create comprehensive test data for Morgan persona end-to-end testing
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
            },
            'Weekend Morning' => {
                description => 'Saturday 9:00-11:00 AM',
                pattern => 'weekend',
                start_time => '09:00',
                end_time => '11:00'
            }
        },
        enrollment_rules => {
            same_session_for_siblings => 1
        }
    })
});

# Create multiple locations representing a growing organization
my @locations = (
    Registry::DAO::Location->create($db, {
        name => 'Downtown Learning Center',
        address_info => {
            street_address => '123 Education Ave',
            city => 'Metro City',
            state => 'TS',
            postal_code => '12345'
        },
        capacity => 30,
        metadata => encode_json({
            facilities => ['Computer lab', 'Science lab', 'Library', 'Art room']
        })
    }),
    Registry::DAO::Location->create($db, {
        name => 'Westside Community Hub',
        address_info => {
            street_address => '456 Community Blvd',
            city => 'Westtown',
            state => 'TS',
            postal_code => '12346'
        },
        capacity => 20,
        metadata => encode_json({
            facilities => ['Meeting rooms', 'Kitchen', 'Playground']
        })
    }),
    Registry::DAO::Location->create($db, {
        name => 'Northside Branch',
        address_info => {
            street_address => '789 Innovation Dr',
            city => 'Northville',
            state => 'TS',
            postal_code => '12347'
        },
        capacity => 25,
        metadata => encode_json({
            facilities => ['Computer lab', 'Makerspace', 'Conference room']
        })
    }),
    Registry::DAO::Location->create($db, {
        name => 'Suburban Family Center',
        address_info => {
            street_address => '321 Family Way',
            city => 'Suburbia',
            state => 'TS',
            postal_code => '12348'
        },
        capacity => 18,
        metadata => encode_json({
            facilities => ['Classrooms', 'Gym', 'Outdoor space']
        })
    })
);

# Create teaching staff
my @teachers = (
    Registry::DAO::User->create($db, {
        name => 'Dr. Sarah Martinez',
        username => 'sarah_martinez',
        first_name => 'Sarah',
        last_name => 'Martinez',
        email => 'sarah.martinez@example.com',
        user_type => 'staff',
        password => 'test123'
    }),
    Registry::DAO::User->create($db, {
        name => 'Prof. David Kim',
        username => 'david_kim',
        first_name => 'David',
        last_name => 'Kim',
        email => 'david.kim@example.com',
        user_type => 'staff',
        password => 'test123'
    }),
    Registry::DAO::User->create($db, {
        name => 'Ms. Lisa Chen',
        username => 'lisa_chen',
        first_name => 'Lisa',
        last_name => 'Chen',
        email => 'lisa.chen@example.com',
        user_type => 'staff',
        password => 'test123'
    }),
    Registry::DAO::User->create($db, {
        name => 'Mr. Alex Johnson',
        username => 'alex_johnson',
        first_name => 'Alex',
        last_name => 'Johnson',
        email => 'alex.johnson@example.com',
        user_type => 'staff',
        password => 'test123'
    })
);

# Create Morgan (Program Developer persona)
my $morgan = Registry::DAO::User->create($db, {
    name => 'Morgan Developer',
    username => 'morgan_developer',
    first_name => 'Morgan',
    last_name => 'Developer',
    email => 'morgan@example.com',
    user_type => 'staff',
    password => 'test123'
});

# Create admin for oversight
my $admin = Registry::DAO::User->create($db, {
    name => 'Admin User',
    username => 'admin_user',
    first_name => 'Admin',
    last_name => 'User',
    email => 'admin@example.com',
    user_type => 'staff',
    password => 'test123'
});

# Create some test families for enrollment testing
my @families = ();
for my $i (1..5) {
    my $family = Registry::DAO::Family->create($db, {
        primary_parent_name => "Parent $i",
        primary_parent_email => "parent$i\@example.com",
        billing_address => {
            street_address => "$i00 Family St",
            city => 'Familytown',
            state => 'TS',
            postal_code => '12349'
        }
    });
    push @families, $family;
}

# Set up workflows
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

# Test complete Morgan persona user journey
subtest 'Morgan Complete User Journey: Curriculum-First Program Development' => sub {
    my $processor = Registry::WorkflowProcessor->new();

    # Morgan's Mental Model: Start with curriculum concept, scale to multiple locations
    # Journey: Design program → Create program → Deploy strategically across locations

    # PHASE 1: Program Design and Creation
    plan_subtest('Program Design and Creation', sub {
        my $creation_run = $creation_workflow->create_run($db);

        # Morgan selects program type based on target audience and delivery model
        my $result = $processor->process_step($db, $creation_workflow->id, $creation_run->id,
            'program-type-selection', {
                program_type_id => $after_school_type->id
            });
        is($result->{next_step}, 'curriculum-details', 'Journey: Program type selected');

        # Morgan designs comprehensive curriculum with clear learning outcomes
        $result = $processor->process_step($db, $creation_workflow->id, $creation_run->id,
            'curriculum-details', {
                program_name => 'Digital Media Creation Academy',
                program_description => 'Students learn digital storytelling, video production, and multimedia design while developing 21st-century skills',
                learning_objectives => [
                    'Digital storytelling techniques and narrative structure',
                    'Video production skills including filming and editing',
                    'Graphic design and visual communication',
                    'Collaboration and project management skills',
                    'Critical media literacy and ethical content creation'
                ],
                materials_needed => [
                    'Computers/laptops with video editing software',
                    'Digital cameras and tripods',
                    'Audio recording equipment',
                    'Graphics tablets',
                    'Green screen setup',
                    'Presentation equipment'
                ],
                curriculum_notes => 'Program culminates in student film festival showcasing final projects. Emphasizes both technical skills and creative expression.'
            });
        is($result->{next_step}, 'requirements-and-patterns', 'Journey: Curriculum designed');

        # Morgan sets age-appropriate requirements and staffing needs
        $result = $processor->process_step($db, $creation_workflow->id, $creation_run->id,
            'requirements-and-patterns', {
                age_min => 12,
                age_max => 16,
                prerequisites => 'Basic computer skills, interest in digital media',
                staff_requirements => '1 lead instructor with media/film background, 1 assistant per 10 students',
                safety_notes => 'Internet safety protocols required, supervised equipment use',
                schedule_pattern => 'weekly',
                session_duration => 150  # 2.5 hours for project-based work
            });
        is($result->{next_step}, 'review-and-create', 'Journey: Requirements defined');

        # Morgan reviews and creates the program
        my $initial_programs = $db->query('SELECT COUNT(*) FROM projects')->array->[0];
        $result = $processor->process_step($db, $creation_workflow->id, $creation_run->id,
            'review-and-create', {
                confirm_create => 1
            });
        is($result->{next_step}, 'complete', 'Journey: Program creation confirmed');

        my $final_programs = $db->query('SELECT COUNT(*) FROM projects')->array->[0];
        is($final_programs, $initial_programs + 1, 'Journey: Program created in database');

        # Verify program characteristics
        my $created_program = Registry::DAO::Project->new(name => 'Digital Media Creation Academy')->load($db);
        ok($created_program, 'Journey: Program accessible');
        is($created_program->program_type_slug, 'after-school', 'Journey: Correct program type');

        my $metadata = decode_json($created_program->metadata);
        is($metadata->{age_min}, 12, 'Journey: Target age range set correctly');
        is($metadata->{session_duration}, 150, 'Journey: Extended session time for project work');
        ok($metadata->{learning_objectives}, 'Journey: Learning objectives preserved');

        return $created_program;
    });

    my $media_program = plan_subtest('Program Design and Creation');

    # PHASE 2: Strategic Location Deployment
    plan_subtest('Strategic Multi-Location Deployment', sub {
        my $assignment_run = $assignment_workflow->create_run($db);

        # Morgan selects the newly created program
        my $result = $processor->process_step($db, $assignment_workflow->id, $assignment_run->id,
            'select-program', {
                project_id => $media_program->id
            });
        is($result->{next_step}, 'choose-locations', 'Journey: Program selected for deployment');

        # Morgan strategically selects locations based on facilities and target demographics
        # Chooses 3 of 4 locations: downtown (tech facilities), northside (makerspace), suburban (family-friendly)
        $result = $processor->process_step($db, $assignment_workflow->id, $assignment_run->id,
            'choose-locations', {
                location_ids => [$locations[0]->id, $locations[2]->id, $locations[3]->id]
            });
        is($result->{next_step}, 'configure-location', 'Journey: Strategic locations selected');

        # Morgan configures each location with tailored capacity and scheduling
        $result = $processor->process_step($db, $assignment_workflow->id, $assignment_run->id,
            'configure-location', {
                location_configs => {
                    $locations[0]->id => {  # Downtown Learning Center
                        capacity => 20,  # Larger capacity with tech facilities
                        schedule => 'Weekday Afternoon',
                        notes => 'Full tech setup with professional editing suites. Primary location for advanced projects.'
                    },
                    $locations[2]->id => {  # Northside Branch
                        capacity => 16,  # Makerspace integration
                        schedule => 'Weekend Morning',
                        pricing_override => 125.00,  # Premium for weekend and special facilities
                        notes => 'Makerspace integration allows for physical media projects and prototyping.'
                    },
                    $locations[3]->id => {  # Suburban Family Center
                        capacity => 14,  # Family-friendly sizing
                        schedule => 'Weekday Afternoon',
                        pricing_override => 95.00,  # Community pricing
                        notes => 'Family-oriented environment, emphasis on positive content creation.'
                    }
                }
            });
        is($result->{next_step}, 'generate-events', 'Journey: Locations configured with differentiation');

        # Morgan generates events with strategic teacher assignments
        my $initial_sessions = $db->query('SELECT COUNT(*) FROM sessions')->array->[0];
        my $start_date = DateTime->now->add(days => 14)->ymd;

        $result = $processor->process_step($db, $assignment_workflow->id, $assignment_run->id,
            'generate-events', {
                confirm_generation => 1,
                generation_params => {
                    start_date => $start_date,
                    duration_weeks => 12  # Full semester program
                },
                teacher_assignments => {
                    $locations[0]->id => $teachers[0]->id,  # Lead instructor at main location
                    $locations[2]->id => $teachers[1]->id,  # Tech-savvy instructor for makerspace
                    $locations[3]->id => $teachers[2]->id   # Family-oriented instructor
                }
            });
        is($result->{next_step}, 'complete', 'Journey: Events generated successfully');

        my $final_sessions = $db->query('SELECT COUNT(*) FROM sessions')->array->[0];
        is($final_sessions, $initial_sessions + 3, 'Journey: Three sessions created');

        return { media_program => $media_program, sessions_created => 3 };
    });

    my $deployment_result = plan_subtest('Strategic Multi-Location Deployment');

    # PHASE 3: Program Verification and System Integration
    plan_subtest('Program Verification and System Integration', sub {
        my $media_program = $deployment_result->{media_program};

        # Verify session characteristics match Morgan's strategic planning
        my $sessions = $db->query('
            SELECT s.*, l.name as location_name, l.capacity as location_capacity
            FROM sessions s
            JOIN locations l ON s.location_id = l.id
            WHERE s.project_id = ?
            ORDER BY l.name
        ', $media_program->id)->hashes;

        is(scalar(@$sessions), 3, 'Journey: All planned sessions created');

        # Verify location-specific configurations
        my ($downtown_session) = grep { $_->{location_name} eq 'Downtown Learning Center' } @$sessions;
        is($downtown_session->{capacity}, 20, 'Journey: Downtown capacity optimized for tech facilities');

        my ($northside_session) = grep { $_->{location_name} eq 'Northside Branch' } @$sessions;
        is($northside_session->{capacity}, 16, 'Journey: Northside sized for makerspace integration');

        my ($suburban_session) = grep { $_->{location_name} eq 'Suburban Family Center' } @$sessions;
        is($suburban_session->{capacity}, 14, 'Journey: Suburban sized for family environment');

        # Verify teacher assignments align with location strategies
        my $teacher_assignments = $db->query('
            SELECT st.*, s.location_id, u.name as teacher_name, l.name as location_name
            FROM session_teachers st
            JOIN sessions s ON st.session_id = s.id
            JOIN users u ON st.user_id = u.id
            JOIN locations l ON s.location_id = l.id
            WHERE s.project_id = ?
            ORDER BY l.name
        ', $media_program->id)->hashes;

        is(scalar(@$teacher_assignments), 3, 'Journey: All strategic teacher assignments made');

        # Verify events span full duration
        my $total_events = $db->query('
            SELECT COUNT(*)
            FROM events e
            JOIN sessions s ON e.session_id = s.id
            WHERE s.project_id = ?
        ', $media_program->id)->array->[0];
        ok($total_events >= 36, 'Journey: Sufficient events for 12-week program across 3 locations');

        # Verify program is ready for enrollment
        my $enrollment_ready_sessions = $db->query('
            SELECT COUNT(*)
            FROM sessions s
            WHERE s.project_id = ? AND s.capacity > 0
        ', $media_program->id)->array->[0];
        is($enrollment_ready_sessions, 3, 'Journey: All sessions ready for enrollment');

        return $media_program;
    });
};

# Test Morgan's ability to manage multiple programs efficiently
subtest 'Morgan Multi-Program Management: Scaling Operations' => sub {
    my $processor = Registry::WorkflowProcessor->new();

    # Morgan creates a second, complementary program
    my $creation_run = $creation_workflow->create_run($db);

    # Quick creation of coding bootcamp program
    $processor->process_step($db, $creation_workflow->id, $creation_run->id,
        'program-type-selection', { program_type_id => $after_school_type->id });

    $processor->process_step($db, $creation_workflow->id, $creation_run->id,
        'curriculum-details', {
            program_name => 'Young Coders Bootcamp',
            program_description => 'Intensive programming course covering web development, game design, and computational thinking',
            learning_objectives => [
                'Programming fundamentals in Python and JavaScript',
                'Web development with HTML, CSS, and frameworks',
                'Game design and development',
                'Computational thinking and problem solving',
                'Version control and collaborative coding'
            ],
            materials_needed => [
                'Computers with coding environments',
                'Code editors and development tools',
                'Online learning platforms access',
                'Project hosting accounts'
            ]
        });

    $processor->process_step($db, $creation_workflow->id, $creation_run->id,
        'requirements-and-patterns', {
            age_min => 10,
            age_max => 15,
            prerequisites => 'Basic typing skills, logical thinking aptitude',
            staff_requirements => '1 senior developer instructor, 1 TA per 8 students',
            schedule_pattern => 'weekly',
            session_duration => 120
        });

    $processor->process_step($db, $creation_workflow->id, $creation_run->id,
        'review-and-create', { confirm_create => 1 });

    my $coding_program = Registry::DAO::Project->new(name => 'Young Coders Bootcamp')->load($db);
    ok($coding_program, 'Scaling: Second program created');

    # Morgan deploys to different locations with overlap strategy
    my $assignment_run = $assignment_workflow->create_run($db);

    $processor->process_step($db, $assignment_workflow->id, $assignment_run->id,
        'select-program', { project_id => $coding_program->id });

    # Strategic overlap: downtown and westside for coding, different from media program's footprint
    $processor->process_step($db, $assignment_workflow->id, $assignment_run->id,
        'choose-locations', {
            location_ids => [$locations[0]->id, $locations[1]->id]  # Downtown and Westside
        });

    $processor->process_step($db, $assignment_workflow->id, $assignment_run->id,
        'configure-location', {
            location_configs => {
                $locations[0]->id => {  # Downtown (overlap with media program)
                    capacity => 16,
                    schedule => 'Weekend Morning',  # Different time to avoid conflict
                    notes => 'Shared tech facilities with media program, scheduled for non-overlap'
                },
                $locations[1]->id => {  # Westside (new location)
                    capacity => 12,
                    schedule => 'Weekday Afternoon',
                    pricing_override => 85.00,  # Community-friendly pricing
                    notes => 'Community hub location, focus on accessibility and inclusion'
                }
            }
        });

    my $pre_coding_sessions = $db->query('SELECT COUNT(*) FROM sessions WHERE project_id = ?', $coding_program->id)->array->[0];
    my $start_date = DateTime->now->add(days => 21)->ymd;

    $processor->process_step($db, $assignment_workflow->id, $assignment_run->id,
        'generate-events', {
            confirm_generation => 1,
            generation_params => {
                start_date => $start_date,
                duration_weeks => 10
            },
            teacher_assignments => {
                $locations[0]->id => $teachers[3]->id,  # Different teacher for coding focus
                $locations[1]->id => $teachers[1]->id   # Reuse teacher across programs
            }
        });

    my $post_coding_sessions = $db->query('SELECT COUNT(*) FROM sessions WHERE project_id = ?', $coding_program->id)->array->[0];
    is($post_coding_sessions, $pre_coding_sessions + 2, 'Scaling: Coding program deployed');

    # Verify Morgan now has comprehensive program portfolio
    my $total_programs = $db->query('SELECT COUNT(*) FROM projects')->array->[0];
    is($total_programs, 2, 'Scaling: Two programs in portfolio');

    my $total_sessions = $db->query('SELECT COUNT(*) FROM sessions')->array->[0];
    is($total_sessions, 5, 'Scaling: Five total sessions across programs');

    # Verify location utilization efficiency
    my $location_usage = $db->query('
        SELECT l.name, COUNT(s.id) as session_count
        FROM locations l
        LEFT JOIN sessions s ON l.id = s.location_id
        GROUP BY l.id, l.name
        ORDER BY l.name
    ')->hashes;

    my ($downtown_usage) = grep { $_->{name} eq 'Downtown Learning Center' } @$location_usage;
    is($downtown_usage->{session_count}, 2, 'Scaling: Downtown efficiently hosts multiple programs');

    # Verify teacher resource optimization
    my $teacher_utilization = $db->query('
        SELECT u.name, COUNT(st.session_id) as assignments
        FROM users u
        LEFT JOIN session_teachers st ON u.id = st.user_id
        WHERE u.role = ?
        GROUP BY u.id, u.name
        ORDER BY assignments DESC
    ', 'teacher')->hashes;

    my $max_assignments = $teacher_utilization->[0]->{assignments};
    ok($max_assignments <= 2, 'Scaling: No teacher over-assigned');
    my $total_assignments = 0;
    $total_assignments += $_->{assignments} for @$teacher_utilization;
    is($total_assignments, 5, 'Scaling: All sessions have teacher assignments');
};

# Test end-to-end enrollment capability
subtest 'Morgan Program Success: Enrollment and Operations' => sub {
    # Simulate family enrollment in Morgan's programs
    my $media_sessions = $db->query('
        SELECT s.*, l.name as location_name
        FROM sessions s
        JOIN locations l ON s.location_id = l.id
        JOIN projects p ON s.project_id = p.id
        WHERE p.name = ?
    ', 'Digital Media Creation Academy')->hashes;

    my $coding_sessions = $db->query('
        SELECT s.*, l.name as location_name
        FROM sessions s
        JOIN locations l ON s.location_id = l.id
        JOIN projects p ON s.project_id = p.id
        WHERE p.name = ?
    ', 'Young Coders Bootcamp')->hashes;

    # Simulate enrollments across programs
    my $total_enrollments = 0;
    for my $session (@$media_sessions) {
        # Enroll 2-3 families per media session
        my $enrollments = int(rand(2)) + 2;
        for my $i (1..$enrollments) {
            my $family_idx = int(rand(@families));
            my $enrollment = Registry::DAO::Enrollment->create($db, {
                session_id => $session->{id},
                family_id => $families[$family_idx]->id,
                status => 'enrolled',
                enrollment_date => DateTime->now->ymd
            });
            $total_enrollments++ if $enrollment;
        }
    }

    for my $session (@$coding_sessions) {
        # Enroll 1-2 families per coding session
        my $enrollments = int(rand(2)) + 1;
        for my $i (1..$enrollments) {
            my $family_idx = int(rand(@families));
            my $enrollment = Registry::DAO::Enrollment->create($db, {
                session_id => $session->{id},
                family_id => $families[$family_idx]->id,
                status => 'enrolled',
                enrollment_date => DateTime->now->ymd
            });
            $total_enrollments++ if $enrollment;
        }
    }

    ok($total_enrollments > 0, 'Success: Programs attracting enrollments');

    # Verify session utilization
    my $utilization_stats = $db->query('
        SELECT
            p.name as program_name,
            l.name as location_name,
            s.capacity,
            COUNT(e.id) as enrolled,
            ROUND((COUNT(e.id)::float / s.capacity) * 100, 1) as utilization_percent
        FROM sessions s
        JOIN projects p ON s.project_id = p.id
        JOIN locations l ON s.location_id = l.id
        LEFT JOIN enrollments e ON s.id = e.session_id AND e.status = ?
        GROUP BY p.id, p.name, l.id, l.name, s.id, s.capacity
        ORDER BY p.name, l.name
    ', 'enrolled')->hashes;

    ok(scalar(@$utilization_stats) >= 5, 'Success: All sessions operational');

    # Check that programs are attracting diverse enrollment
    my $program_diversity = $db->query('
        SELECT p.name, COUNT(DISTINCT e.family_id) as unique_families
        FROM projects p
        JOIN sessions s ON p.id = s.project_id
        JOIN enrollments e ON s.id = e.session_id
        WHERE e.status = ?
        GROUP BY p.id, p.name
    ', 'enrolled')->hashes;

    ok(scalar(@$program_diversity) >= 1, 'Success: Programs attracting families');

    # Verify Morgan's strategic planning paid off
    my $location_success = $db->query('
        SELECT
            l.name,
            COUNT(DISTINCT p.id) as programs_offered,
            COUNT(DISTINCT s.id) as sessions_running,
            COUNT(e.id) as total_enrollments
        FROM locations l
        LEFT JOIN sessions s ON l.id = s.location_id
        LEFT JOIN projects p ON s.project_id = p.id
        LEFT JOIN enrollments e ON s.id = e.session_id AND e.status = ?
        GROUP BY l.id, l.name
        HAVING COUNT(DISTINCT s.id) > 0
        ORDER BY total_enrollments DESC
    ', 'enrolled')->hashes;

    ok(scalar(@$location_success) >= 3, 'Success: Multiple locations actively serving families');

    # Verify operational readiness
    my $operational_health = $db->query('
        SELECT
            COUNT(DISTINCT p.id) as total_programs,
            COUNT(DISTINCT s.id) as total_sessions,
            COUNT(DISTINCT l.id) as locations_utilized,
            COUNT(DISTINCT st.user_id) as teachers_assigned,
            COUNT(e.id) as total_enrollments
        FROM projects p
        JOIN sessions s ON p.id = s.project_id
        JOIN locations l ON s.location_id = l.id
        LEFT JOIN session_teachers st ON s.id = st.session_id
        LEFT JOIN enrollments e ON s.id = e.session_id AND e.status = ?
    ', 'enrolled')->hash;

    is($operational_health->{total_programs}, 2, 'Success: Portfolio of 2 programs');
    is($operational_health->{total_sessions}, 5, 'Success: 5 sessions operational');
    ok($operational_health->{locations_utilized} >= 3, 'Success: Multi-location deployment');
    ok($operational_health->{teachers_assigned} >= 3, 'Success: Adequate staffing');
    ok($operational_health->{total_enrollments} > 0, 'Success: Active enrollments');
};

done_testing();

# Helper function for subtests that return values
sub plan_subtest($name, $code = undef) {
    if ($code) {
        subtest $name => sub {
            my $result = $code->();
            done_testing();
            return $result;
        };
    } else {
        # This is the retrieval call
        return shift;
    }
}