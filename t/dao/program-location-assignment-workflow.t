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
use Registry::DAO::Location;
use Registry::DAO::Session;
use Registry::DAO::Event;
use Registry::DAO::ProgramType;
use Registry::DAO::WorkflowSteps::SelectProgram;
use Registry::DAO::WorkflowSteps::ChooseLocations;
use Registry::DAO::WorkflowSteps::ConfigureLocation;
use Registry::DAO::WorkflowSteps::GenerateEvents;
use Mojo::JSON qw(encode_json decode_json);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

# Create test tenant and set up schema
my $tenant = Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Test Program Location Tenant',
    slug => 'test_program_location',
});
$dao->db->query('SELECT clone_schema(?)', 'test_program_location');

# Switch to tenant schema
$dao = Registry::DAO->new(url => $test_db->uri, schema => 'test_program_location');
my $db = $dao->db;

# Create test program type
my $program_type = Registry::DAO::ProgramType->create($db, {
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
        }
    })
});

# Create test programs
my $robotics_program = Registry::DAO::Project->create($db, {
    name => 'Robotics Club',
    description => 'Learn robotics and programming',
    program_type_slug => 'after-school',
    metadata => encode_json({
        age_min => 8,
        age_max => 12,
        duration_weeks => 10,
        program_type_config => decode_json($program_type->config)
    })
});

my $art_program = Registry::DAO::Project->create($db, {
    name => 'Creative Arts',
    description => 'Explore artistic creativity',
    program_type_slug => 'after-school',
    metadata => encode_json({
        age_min => 6,
        age_max => 14,
        duration_weeks => 8
    })
});

# Create test locations
my $downtown_location = Registry::DAO::Location->create($db, {
    name => 'Downtown Community Center',
    address_info => {
        street_address => '123 Main St',
        city => 'Downtown',
        state => 'TS',
        postal_code => '12345'
    },
    capacity => 25,
    metadata => encode_json({
        facilities => ['Computer lab', 'Art room', 'Gymnasium']
    })
});

my $north_location = Registry::DAO::Location->create($db, {
    name => 'North Side Branch',
    address_info => {
        street_address => '456 Oak Ave',
        city => 'Northtown',
        state => 'TS',
        postal_code => '12346'
    },
    capacity => 20,
    metadata => encode_json({
        facilities => ['Classroom', 'Library']
    })
});

my $suburban_location = Registry::DAO::Location->create($db, {
    name => 'Suburban Recreation Center',
    address_info => {
        street_address => '789 Pine Rd',
        city => 'Suburbia',
        state => 'TS',
        postal_code => '12347'
    },
    capacity => 30,
    metadata => encode_json({
        facilities => ['Computer lab', 'Meeting rooms', 'Kitchen']
    })
});

# Create test teachers
my $teacher1 = Registry::DAO::User->create($db, {
    name => 'Sarah Johnson',
    username => 'sarah_johnson',
    first_name => 'Sarah',
    last_name => 'Johnson',
    email => 'sarah@example.com',
    user_type => 'staff',
    password => 'test123'
});

my $teacher2 = Registry::DAO::User->create($db, {
    name => 'Mike Chen',
    username => 'mike_chen',
    first_name => 'Mike',
    last_name => 'Chen',
    email => 'mike@example.com',
    user_type => 'staff',
    password => 'test123'
});

# Create test user (Morgan persona)
my $morgan = Registry::DAO::User->create($db, {
    name => 'Morgan Developer',
    username => 'morgan_developer',
    email => 'morgan@example.com',
    user_type => 'staff',
    password => 'test123'
});

# Create workflow
my $workflow = Registry::DAO::Workflow->create($db, {
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

# Test Step 1: Select Program
subtest 'Select Program Step' => sub {
    my $run = $workflow->create_run($db);
    my $step = Registry::DAO::WorkflowSteps::SelectProgram->new(
        workflow => $workflow,
        id => 'select-program'
    );

    # Test preparation - should return available programs
    my $result = $step->process($db, {});
    is($result->{next_step}, 'select-program', 'Returns same step when no selection made');
    my $data = $result->{data};
    ok($data->{projects}, 'Projects data provided');
    is(scalar(@{$data->{projects}}), 2, 'Both programs available');

    # Test valid selection
    $result = $step->process($db, { project_id => $robotics_program->id });
    is($result->{next_step}, 'choose-locations', 'Advances to location selection');

    # Verify data was stored
    $run = $workflow->latest_run($db);
    is($run->data->{project_id}, $robotics_program->id, 'Project ID stored');
    is($run->data->{project_name}, 'Robotics Club', 'Project name stored');
    ok($run->data->{project_metadata}, 'Project metadata stored');

    # Test invalid selection
    $result = $step->process($db, { project_id => 99999 });
    is($result->{next_step}, 'select-program', 'Stays on step with invalid selection');
    ok($result->{errors}, 'Errors provided for invalid selection');
};

# Test Step 2: Choose Locations
subtest 'Choose Locations Step' => sub {
    my $run = $workflow->latest_run($db);
    my $step = Registry::DAO::WorkflowSteps::ChooseLocations->new(
        workflow => $workflow,
        id => 'choose-locations'
    );

    # Test form display
    my $result = $step->process($db, {});
    is($result->{next_step}, 'choose-locations', 'Returns same step when no data submitted');
    my $data = $result->{data};
    ok($data->{locations}, 'Locations data provided');
    is($data->{project_name}, 'Robotics Club', 'Project name included in data');
    is(scalar(@{$data->{locations}}), 3, 'All locations available');

    # Test single location selection
    $result = $step->process($db, { location_ids => [$downtown_location->id] });
    is($result->{next_step}, 'configure-location', 'Advances to configuration step');

    # Verify data was stored
    $run = $workflow->latest_run($db);
    my $selected = $run->data->{selected_locations};
    is(scalar(@$selected), 1, 'One location selected');
    is($selected->[0]->{id}, $downtown_location->id, 'Correct location ID stored');
    is($selected->[0]->{name}, 'Downtown Community Center', 'Location name stored');

    # Test multiple location selection
    $result = $step->process($db, {
        location_ids => [$downtown_location->id, $north_location->id, $suburban_location->id]
    });
    is($result->{next_step}, 'configure-location', 'Handles multiple locations');

    $run = $workflow->latest_run($db);
    $selected = $run->data->{selected_locations};
    is(scalar(@$selected), 3, 'Three locations selected');

    # Test invalid location
    $result = $step->process($db, { location_ids => [99999] });
    is($result->{next_step}, 'choose-locations', 'Stays on step with invalid location');
    ok($result->{errors}, 'Errors provided for invalid location');
};

# Test Step 3: Configure Location
subtest 'Configure Location Step' => sub {
    my $run = $workflow->latest_run($db);
    my $step = Registry::DAO::WorkflowSteps::ConfigureLocation->new(
        workflow => $workflow,
        id => 'configure-location'
    );

    # Test form display
    my $result = $step->process($db, {});
    is($result->{next_step}, 'configure-location', 'Returns same step for configuration form');
    my $data = $result->{data};
    is($data->{project_name}, 'Robotics Club', 'Project name in data');
    is(scalar(@{$data->{selected_locations}}), 3, 'All selected locations in data');
    ok($data->{standard_times}, 'Standard times provided');

    # Test valid configuration
    my $location_configs = {
        $downtown_location->id => {
            capacity => 20,
            schedule => 'Weekday Afternoon',
            notes => 'Downtown location with full facilities'
        },
        $north_location->id => {
            capacity => 15,
            schedule => 'Weekend Morning',
            pricing_override => 85.00,
            notes => 'Smaller location, reduced capacity'
        },
        $suburban_location->id => {
            capacity => 25,
            schedule => 'Weekday Afternoon',
            pricing_override => 110.00
        }
    };

    $result = $step->process($db, { location_configs => $location_configs });
    is($result->{next_step}, 'generate-events', 'Advances to event generation');

    # Verify data was stored
    $run = $workflow->latest_run($db);
    my $configured = $run->data->{configured_locations};
    is(scalar(@$configured), 3, 'All locations configured');

    # Check specific configuration details
    my ($downtown_config) = grep { $_->{id} eq $downtown_location->id } @$configured;
    is($downtown_config->{capacity}, 20, 'Downtown capacity set correctly');
    is($downtown_config->{schedule}, 'Weekday Afternoon', 'Downtown schedule set');

    my ($north_config) = grep { $_->{id} eq $north_location->id } @$configured;
    is($north_config->{capacity}, 15, 'North capacity set correctly');
    is($north_config->{pricing_override}, 85.00, 'North pricing override set');

    # Test invalid capacity (zero)
    $result = $step->process($db, {
        location_configs => {
            $downtown_location->id => { capacity => 0 }
        }
    });
    is($result->{next_step}, 'configure-location', 'Stays on step with invalid capacity');
    ok($result->{errors}, 'Errors provided for invalid capacity');
    like($result->{errors}->[0], qr/greater than 0/i, 'Error mentions capacity requirement');
};

# Test Step 4: Generate Events
subtest 'Generate Events Step' => sub {
    my $run = $workflow->latest_run($db);
    my $step = Registry::DAO::WorkflowSteps::GenerateEvents->new(
        workflow => $workflow,
        id => 'generate-events'
    );

    # Test form display
    my $result = $step->process($db, {});
    is($result->{next_step}, 'generate-events', 'Returns same step for generation form');
    my $data = $result->{data};
    is($data->{project_name}, 'Robotics Club', 'Project name in data');
    ok($data->{configured_locations}, 'Configured locations in data');
    ok($data->{available_teachers}, 'Available teachers provided');

    # Count initial sessions and events
    my $initial_sessions = $db->query('SELECT COUNT(*) FROM sessions')->array->[0];
    my $initial_events = $db->query('SELECT COUNT(*) FROM events')->array->[0];

    # Test event generation
    my $start_date = DateTime->now->add(days => 7)->ymd;
    my $generation_params = {
        start_date => $start_date,
        duration_weeks => 8
    };
    my $teacher_assignments = {
        $downtown_location->id => $teacher1->id,
        $suburban_location->id => $teacher2->id
        # Leave north location without teacher assignment
    };

    $result = $step->process($db, {
        confirm_generation => 1,
        generation_params => $generation_params,
        teacher_assignments => $teacher_assignments
    });
    is($result->{next_step}, 'complete', 'Advances to completion step');

    # Verify sessions were created
    my $final_sessions = $db->query('SELECT COUNT(*) FROM sessions')->array->[0];
    is($final_sessions, $initial_sessions + 3, 'Three sessions created');

    # Verify events were created (8 weeks per session)
    my $final_events = $db->query('SELECT COUNT(*) FROM events')->array->[0];
    ok($final_events > $initial_events, 'Events were created');

    # Verify session details
    my $sessions = $db->query('
        SELECT s.*, l.name as location_name
        FROM sessions s
        JOIN locations l ON s.location_id = l.id
        WHERE s.project_id = ?
    ', $robotics_program->id)->hashes;

    is(scalar(@$sessions), 3, 'Correct number of sessions');

    # Check downtown session
    my ($downtown_session) = grep { $_->{location_name} eq 'Downtown Community Center' } @$sessions;
    ok($downtown_session, 'Downtown session created');
    is($downtown_session->{capacity}, 20, 'Downtown session has correct capacity');

    # Check teacher assignments
    my $teacher_assignments_count = $db->query('
        SELECT COUNT(*) FROM session_teachers
        WHERE session_id IN (SELECT id FROM sessions WHERE project_id = ?)
    ', $robotics_program->id)->array->[0];
    is($teacher_assignments_count, 2, 'Two teacher assignments created');

    # Test missing required parameters
    $result = $step->process($db, { confirm_generation => 1 });
    is($result->{next_step}, 'generate-events', 'Stays on step with missing parameters');
    ok($result->{errors}, 'Errors provided for missing parameters');
};

# Test Complete Workflow Integration
subtest 'Complete Workflow Integration Test' => sub {
    # Start fresh workflow run for art program
    my $new_run = $workflow->create_run($db);

    # Simulate complete workflow execution
    my $processor = Registry::WorkflowProcessor->new();

    # Step 1: Select art program
    my $result = $processor->process_step($db, $workflow->id, $new_run->id, 'select-program', {
        project_id => $art_program->id
    });
    is($result->{next_step}, 'choose-locations', 'Integration: Program selection works');

    # Step 2: Choose two locations
    $result = $processor->process_step($db, $workflow->id, $new_run->id, 'choose-locations', {
        location_ids => [$downtown_location->id, $suburban_location->id]
    });
    is($result->{next_step}, 'configure-location', 'Integration: Location selection works');

    # Step 3: Configure locations
    $result = $processor->process_step($db, $workflow->id, $new_run->id, 'configure-location', {
        location_configs => {
            $downtown_location->id => { capacity => 18, schedule => 'Weekend Morning' },
            $suburban_location->id => { capacity => 22, schedule => 'Weekday Afternoon' }
        }
    });
    is($result->{next_step}, 'generate-events', 'Integration: Location configuration works');

    # Step 4: Generate events
    my $pre_sessions = $db->query('SELECT COUNT(*) FROM sessions WHERE project_id = ?', $art_program->id)->array->[0];
    my $start_date = DateTime->now->add(days => 14)->ymd;

    $result = $processor->process_step($db, $workflow->id, $new_run->id, 'generate-events', {
        confirm_generation => 1,
        generation_params => {
            start_date => $start_date,
            duration_weeks => 6
        }
    });
    is($result->{next_step}, 'complete', 'Integration: Event generation works');

    my $post_sessions = $db->query('SELECT COUNT(*) FROM sessions WHERE project_id = ?', $art_program->id)->array->[0];
    is($post_sessions, $pre_sessions + 2, 'Integration: Two sessions created for art program');

    # Verify workflow completion data
    $new_run = $workflow->latest_run($db);
    ok($new_run->data->{created_sessions}, 'Created sessions data stored');
    is(scalar(@{$new_run->data->{created_sessions}}), 2, 'Correct number of sessions recorded');
};

# Test Error Handling and Edge Cases
subtest 'Error Handling and Edge Cases' => sub {
    my $run = $workflow->create_run($db);

    # Test configuration with duplicate location
    my $step = Registry::DAO::WorkflowSteps::ChooseLocations->new(
        workflow => $workflow,
        id => 'choose-locations'
    );

    # Set up program selection first
    $run->data({ project_id => $robotics_program->id, project_name => 'Robotics Club' });
    $run->save($db);

    # Test with duplicate location IDs in array
    my $result = $step->process($db, {
        location_ids => [$downtown_location->id, $downtown_location->id]
    });
    is($result->{next_step}, 'configure-location', 'Handles duplicate location selections');

    # Should only store unique locations
    $run = $workflow->latest_run($db);
    my $selected = $run->data->{selected_locations};
    is(scalar(@$selected), 1, 'Duplicate locations filtered out');

    # Test generation with past date
    my $generate_step = Registry::DAO::WorkflowSteps::GenerateEvents->new(
        workflow => $workflow,
        id => 'generate-events'
    );

    $run->data->{configured_locations} = [{
        id => $downtown_location->id,
        name => 'Downtown Community Center',
        capacity => 20
    }];
    $run->save($db);

    my $past_date = DateTime->now->subtract(days => 5)->ymd;
    $result = $generate_step->process($db, {
        confirm_generation => 1,
        generation_params => {
            start_date => $past_date,
            duration_weeks => 4
        }
    });
    is($result->{next_step}, 'generate-events', 'Rejects past start dates');
    ok($result->{errors}, 'Provides error for past date');
};

done_testing();