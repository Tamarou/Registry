#!/usr/bin/env perl
# ABOUTME: Tests for MultiChildSessionSelection workflow step using real production interfaces
# ABOUTME: Validates session selection for multiple children with age and capacity constraints
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
use Registry::DAO::Family;
use Registry::DAO::Session;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Location;
use Registry::DAO::ProgramType;
use Registry::DAO::WorkflowSteps::MultiChildSessionSelection;
use Mojo::JSON qw(encode_json);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

# Create test tenant and set up schema
my $tenant = Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Test MultiChild Session Tenant',
    slug => 'test_multi_session',
});

# Switch to tenant schema
$dao = Registry::DAO->new(url => $test_db->uri, schema => 'test_multi_session');
my $db = $dao->db;

# Create test data
my $location = Registry::DAO::Location->create($db, {
    name => 'Test Location',
    address_info => {
        street_address => '123 Main St',
        city => 'Test City',
        state => 'TS',
        postal_code => '12345'
    },
    metadata => {}
});

# Create teacher and project
my $teacher = Registry::DAO::User->create($db, {
    name => 'Test Teacher',
    username => 'testteacher',
    email => 'teacher@test.com',
    user_type => 'staff'
});

my $project = Registry::DAO::Project->create($db, {
    name => 'Test Project',
    metadata => {}
});

# Create events with different age ranges
my $event1 = Registry::DAO::Event->create($db, {
    time => '2024-07-01 10:00:00',
    duration => 120,
    location_id => $location->id,
    project_id => $project->id,
    teacher_id => $teacher->id,
    metadata => {},
    capacity => 10,
    min_age => 6,
    max_age => 10
});

my $event2 = Registry::DAO::Event->create($db, {
    time => '2024-07-02 10:00:00',
    duration => 120,
    location_id => $location->id,
    project_id => $project->id,
    teacher_id => $teacher->id,
    metadata => {},
    capacity => 5,
    min_age => 8,
    max_age => 12
});

# Create sessions with future dates and capacity limits
my $session1 = Registry::DAO::Session->create($db, {
    name => 'Morning Session',
    start_date => '2025-12-02',
    end_date => '2025-12-09',
    status => 'published',
    capacity => 10,
    metadata => {}
});

my $session2 = Registry::DAO::Session->create($db, {
    name => 'Afternoon Session',
    start_date => '2025-12-02',
    end_date => '2025-12-09',
    status => 'published',
    capacity => 5,
    metadata => {}
});

# Link events to sessions
$session1->add_events($db, $event1->id);
$session2->add_events($db, $event2->id);

# Create program type with sibling rules
my $program_type = Registry::DAO::ProgramType->create($db, {
    name => 'Family Program',
    slug => 'family-program',
    config => {
        enrollment_rules => {
            same_session_for_siblings => 1
        }
    }
});

# Update project to use program type
$project->update($db, { program_type_slug => $program_type->slug });

# Create workflow
my $workflow = Registry::DAO::Workflow->create($db, {
    name => 'Test Multi-Child Session Workflow',
    slug => 'test-multi-child-session-workflow',
    description => 'Test workflow for multi-child session selection'
});

# Add session selection workflow step
my $session_step_data = Registry::DAO::WorkflowStep->create($db, {
    workflow_id => $workflow->id,
    slug => 'session-selection',
    class => 'Registry::DAO::WorkflowSteps::MultiChildSessionSelection',
    description => 'Session selection step'
});

# Update workflow to set first step
$workflow->update($db, { first_step => 'session-selection' }, { id => $workflow->id });

# Create test parent user
my $parent = Registry::DAO::User->create($db, {
    email    => 'parent@example.com',
    username => 'testparent',
    password => 'password123',
    name => 'Test Parent',
    user_type => 'parent'
});

# Add children to family - one eligible for both sessions, one only for session2
my $child1 = Registry::DAO::Family->add_child($db, $parent->id, {
    child_name => 'Alice Smith',
    birth_date => '2016-03-15',  # 8 years old - eligible for both sessions
    grade => '3',
    medical_info => {},
    emergency_contact => {
        name => 'Emergency Contact',
        phone => '555-0123',
        relationship => 'grandparent'
    }
});

my $child2 = Registry::DAO::Family->add_child($db, $parent->id, {
    child_name => 'Bob Smith',
    birth_date => '2018-06-20',  # 6 years old - only eligible for session1
    grade => '1',
    medical_info => {},
    emergency_contact => {
        name => 'Emergency Contact',
        phone => '555-0123',
        relationship => 'aunt'
    }
});

subtest 'Initial page load without selected children' => sub {
    my $run = $workflow->new_run($db);

    # Get the actual step from database
    my $step = $workflow->get_step($db, { slug => 'session-selection' });

    # Process step without selected_child_ids in run data
    my $result = $step->process($db, {});

    ok $result->{stay}, 'Stays on step';
    ok $result->{errors}, 'Returns errors';
    like $result->{errors}->[0], qr/No children selected/, 'Correct error message';
};

subtest 'Initial page load with selected children' => sub {
    my $run = $workflow->new_run($db);

    # Set up run data as if coming from select-children step
    $run->update_data($db, {
        user_id => $parent->id,
        selected_child_ids => [$child1->id, $child2->id],
        location_id => $location->id,
        program_id => $project->id,
    });

    # Get the actual step from database
    my $step = $workflow->get_step($db, { slug => 'session-selection' });

    # Process step without action (first visit)
    my $result = $step->process($db, {});

    ok $result->{stay}, 'Stays on step for initial load';
    ok !$result->{errors}, 'No errors on initial load';
};

subtest 'Submit without session selections' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data($db, {
        user_id => $parent->id,
        selected_child_ids => [$child1->id, $child2->id],
        location_id => $location->id,
        program_id => $project->id,
    });

    my $step = $workflow->get_step($db, { slug => 'session-selection' });

    my $result = $step->process($db, {
        action => 'select_sessions',
        # No session selections provided
    });

    ok $result->{stay}, 'Stays on step';
    ok $result->{errors}, 'Returns validation errors';
    is scalar(@{$result->{errors}}), 2, 'Two validation errors (one per child)';
    like $result->{errors}->[0], qr/Please select a session for/, 'Child selection error';
};

subtest 'Submit with valid session selections' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data($db, {
        user_id => $parent->id,
        selected_child_ids => [$child1->id, $child2->id],
        location_id => $location->id,
        program_id => $project->id,
    });

    my $step = $workflow->get_step($db, { slug => 'session-selection' });

    my $result = $step->process($db, {
        action => 'select_sessions',
        "session_for_" . $child1->id => $session1->id,
        "session_for_" . $child2->id => $session1->id,
    });

    ok !$result->{stay}, 'Moves to next step';
    ok !$result->{errors}, 'No errors';
    is $result->{next_step}, 'payment', 'Moves to payment step';

    # Check run data was updated
    my $updated_run = $workflow->latest_run($db);
    my $data = $updated_run->data;

    ok $data->{enrollment_items}, 'Enrollment items stored';
    is scalar(@{$data->{enrollment_items}}), 2, 'Two enrollment items';
    ok $data->{session_selections}, 'Session selections stored';

    # Check session selections
    is $data->{session_selections}->{$child1->id}, $session1->id, 'Child1 session stored';
    is $data->{session_selections}->{$child2->id}, $session1->id, 'Child2 session stored';
};

subtest 'Program type sibling rule validation' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data($db, {
        user_id => $parent->id,
        selected_child_ids => [$child1->id, $child2->id],
        location_id => $location->id,
        program_id => $project->id,
    });

    my $step = $workflow->get_step($db, { slug => 'session-selection' });

    # Try to select different sessions for siblings with a program type that requires same session
    my $result = $step->process($db, {
        action => 'select_sessions',
        "session_for_" . $child1->id => $session1->id,
        "session_for_" . $child2->id => $session2->id,  # Different session
    });

    ok $result->{stay}, 'Stays on step';
    ok $result->{errors}, 'Returns validation errors';
    like $result->{errors}->[0], qr/All siblings must be enrolled in the same session/, 'Sibling rule error';
};

subtest 'get_available_sessions method' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data($db, {
        user_id => $parent->id,
        selected_child_ids => [$child1->id, $child2->id],
        location_id => $location->id,
        program_id => $project->id,
    });

    my $step = $workflow->get_step($db, { slug => 'session-selection' });

    # Get available sessions for child1 (9 years old - eligible for both)
    my $available1 = $step->get_available_sessions($db, $location->id, $project->id, $child1);
    is scalar(@$available1), 2, 'Child1 has 2 available sessions';

    # Get available sessions for child2 (7 years old - only eligible for session1)
    my $available2 = $step->get_available_sessions($db, $location->id, $project->id, $child2);
    is scalar(@$available2), 1, 'Child2 has 1 available session';
    is $available2->[0]->{session}->id, $session1->id, 'Child2 eligible for session1';
};

subtest 'Validation method tests' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data($db, { user_id => $parent->id });

    my $step = $workflow->get_step($db, { slug => 'session-selection' });

    # Test select_sessions validation without selections
    my $errors = $step->validate($db, {
        action => 'select_sessions',
        # No session selections
    });

    ok $errors, 'validate() method returns errors when no sessions selected';
    like $errors->[0], qr/Please select at least one session/, 'Correct validation error message';

    # Test with selections
    $errors = $step->validate($db, {
        action => 'select_sessions',
        "session_for_" . $child1->id => $session1->id,
    });

    ok !$errors, 'No validation errors with selections';

    # Test without action
    $errors = $step->validate($db, {});
    ok !$errors, 'No validation errors without action';
};

subtest 'Session capacity constraints' => sub {
    # Create test students and fill up session2 to test capacity constraints
    for my $i (1..5) {
        my $test_student = Registry::DAO::User->create($db, {
            email => "student$i\@test.com",
            username => "student$i",
            name => "Test Student $i",
            user_type => 'parent'
        });

        $db->insert('enrollments', {
            session_id => $session2->id,
            student_id => $test_student->id,
            status => 'active'
        });
    }

    my $run = $workflow->new_run($db);
    $run->update_data($db, {
        user_id => $parent->id,
        selected_child_ids => [$child1->id],
        location_id => $location->id,
        program_id => $project->id,
    });

    my $step = $workflow->get_step($db, { slug => 'session-selection' });

    # Get available sessions for child1 - session2 should be filtered out due to capacity
    my $available1 = $step->get_available_sessions($db, $location->id, $project->id, $child1);

    # Should only show session1 now since session2 is at capacity
    is scalar(@$available1), 1, 'Only 1 session available due to capacity';
    is $available1->[0]->{session}->id, $session1->id, 'Available session is session1';
};

done_testing;