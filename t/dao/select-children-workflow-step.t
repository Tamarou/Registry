#!/usr/bin/env perl
# ABOUTME: Tests for SelectChildren workflow step using real production interfaces
# ABOUTME: Validates child selection, addition, and workflow progression functionality
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
use Registry::DAO::WorkflowSteps::SelectChildren;
use Mojo::JSON qw(encode_json);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

# Create test tenant and set up schema
my $tenant = Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Test SelectChildren Tenant',
    slug => 'test_select_children',
});
$dao->db->query('SELECT clone_schema(?)', 'test_select_children');

# Switch to tenant schema
$dao = Registry::DAO->new(url => $test_db->uri, schema => 'test_select_children');
my $db = $dao->db;

# Create workflow
my $workflow = Registry::DAO::Workflow->create($db, {
    name => 'Test Multi-Child Workflow',
    slug => 'test-multi-child-workflow',
    description => 'Test workflow for multi-child enrollment'
});

# Add select children workflow step
my $select_children_step_data = Registry::DAO::WorkflowStep->create($db, {
    workflow_id => $workflow->id,
    slug => 'select-children',
    class => 'Registry::DAO::WorkflowSteps::SelectChildren',
    description => 'Child selection step'
});

# Update workflow to set first step
$workflow->update($db, { first_step => 'select-children' }, { id => $workflow->id });

# Create test parent user
my $parent = Registry::DAO::User->create($db, {
    email    => 'parent@example.com',
    username => 'testparent',
    password => 'password123',
    name => 'Test Parent',
    user_type => 'parent'
});

# Add existing children to family
my $child1 = Registry::DAO::Family->add_child($db, $parent->id, {
    child_name => 'Alice Smith',
    birth_date => '2016-03-15',  # 8 years old
    grade => '3',
    medical_info => {
        allergies => ['peanuts'],
        medications => [],
        notes => 'No special needs'
    },
    emergency_contact => {
        name => 'Emergency Contact',
        phone => '555-0123',
        relationship => 'grandparent'
    }
});

my $child2 = Registry::DAO::Family->add_child($db, $parent->id, {
    child_name => 'Bob Smith',
    birth_date => '2014-06-20',  # 10 years old
    grade => '5',
    medical_info => {},
    emergency_contact => {
        name => 'Emergency Contact',
        phone => '555-0123',
        relationship => 'aunt'
    }
});

subtest 'Initial page load without user_id' => sub {
    my $run = $workflow->new_run($db);

    # Get the actual step from database
    my $step = $workflow->get_step($db, { slug => 'select-children' });

    # Process step without user_id in run data
    my $result = $step->process($db, {});

    ok $result->{stay}, 'Stays on step';
    ok $result->{errors}, 'Returns errors';
    like $result->{errors}->[0], qr/User not logged in/, 'Correct error message';
};

subtest 'Initial page load with user_id' => sub {
    my $run = $workflow->new_run($db);

    # Set up run data with user_id (as if coming from account-check step)
    $run->update_data($db, {
        user_id => $parent->id,
    });

    # Get the actual step from database
    my $step = $workflow->get_step($db, { slug => 'select-children' });

    # Process step without action (first visit)
    my $result = $step->process($db, {});

    ok $result->{stay}, 'Stays on step for initial load';
    ok !$result->{errors}, 'No errors on initial load';
};

subtest 'Add new child validation errors' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data($db, { user_id => $parent->id });

    my $step = $workflow->get_step($db, { slug => 'select-children' });

    # Test missing required fields
    my $result = $step->process($db, {
        action => 'add_child',
        new_child_name => '',
        new_birth_date => '',
        new_emergency_name => '',
        new_emergency_phone => '',
    });

    ok $result->{stay}, 'Stays on step';
    ok $result->{errors}, 'Returns validation errors';
    is scalar(@{$result->{errors}}), 4, 'Four validation errors';

    my @errors = @{$result->{errors}};
    ok(grep { /Child name is required/ } @errors, 'Child name validation');
    ok(grep { /Birth date is required/ } @errors, 'Birth date validation');
    ok(grep { /Emergency contact name is required/ } @errors, 'Emergency name validation');
    ok(grep { /Emergency contact phone is required/ } @errors, 'Emergency phone validation');
};

subtest 'Add new child with invalid birth date format' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data($db, { user_id => $parent->id });

    my $step = $workflow->get_step($db, { slug => 'select-children' });

    my $result = $step->process($db, {
        action => 'add_child',
        new_child_name => 'Charlie Smith',
        new_birth_date => '03/15/2018',  # Wrong format
        new_emergency_name => 'Emergency Contact',
        new_emergency_phone => '555-0123',
    });

    ok $result->{stay}, 'Stays on step';
    ok $result->{errors}, 'Returns validation errors';
    like $result->{errors}->[0], qr/Birth date must be in YYYY-MM-DD format/, 'Date format validation';
};

subtest 'Successfully add new child' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data($db, { user_id => $parent->id });

    my $step = $workflow->get_step($db, { slug => 'select-children' });

    my $result = $step->process($db, {
        action => 'add_child',
        new_child_name => 'Charlie Smith',
        new_birth_date => '2018-03-15',
        new_grade => 'K',
        new_allergies => 'milk, eggs',
        new_medications => 'inhaler',
        new_medical_notes => 'Uses inhaler for asthma',
        new_emergency_name => 'Emergency Contact',
        new_emergency_phone => '555-0123',
        new_emergency_relationship => 'uncle',
    });

    ok $result->{stay}, 'Stays on step after adding child';
    ok !$result->{errors}, 'No errors when adding valid child';

    # Verify child was actually added to family
    my $family_children = Registry::DAO::Family->list_children($db, $parent->id);
    is scalar(@$family_children), 3, 'Family now has 3 children';

    my $new_child = (grep { $_->child_name eq 'Charlie Smith' } @$family_children)[0];
    ok $new_child, 'New child found in family';
    is $new_child->birth_date, '2018-03-15', 'Birth date stored correctly';
    is $new_child->grade, 'K', 'Grade stored correctly';

    # Check medical info
    my $medical = $new_child->medical_info;
    is_deeply $medical->{allergies}, ['milk', 'eggs'], 'Allergies parsed and stored';
    is_deeply $medical->{medications}, ['inhaler'], 'Medications parsed and stored';
    is $medical->{notes}, 'Uses inhaler for asthma', 'Medical notes stored';

    # Check emergency contact
    my $emergency = $new_child->emergency_contact;
    is $emergency->{name}, 'Emergency Contact', 'Emergency contact name stored';
    is $emergency->{phone}, '555-0123', 'Emergency contact phone stored';
    is $emergency->{relationship}, 'uncle', 'Emergency contact relationship stored';
};

subtest 'Continue without selecting children' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data($db, { user_id => $parent->id });

    my $step = $workflow->get_step($db, { slug => 'select-children' });

    my $result = $step->process($db, {
        action => 'continue',
        # No children selected
    });

    ok $result->{stay}, 'Stays on step';
    ok $result->{errors}, 'Returns errors';
    like $result->{errors}->[0], qr/Please select at least one child/, 'Selection required error';
};

subtest 'Continue with selected children' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data($db, { user_id => $parent->id });

    my $step = $workflow->get_step($db, { slug => 'select-children' });

    my $result = $step->process($db, {
        action => 'continue',
        "child_" . $child1->id => 1,
        "child_" . $child2->id => 1,
    });

    ok !$result->{stay}, 'Moves to next step';
    ok !$result->{errors}, 'No errors';
    is $result->{next_step}, 'session-selection', 'Moves to session-selection step';

    # Check run data was updated
    my $updated_run = $workflow->latest_run($db);
    my $data = $updated_run->data;

    ok $data->{selected_child_ids}, 'Selected child IDs stored';
    is scalar(@{$data->{selected_child_ids}}), 2, 'Two children selected';
    is $data->{enrollment_count}, 2, 'Enrollment count stored';

    # Check that the correct children were selected
    my @selected_ids = sort @{$data->{selected_child_ids}};
    my @expected_ids = sort ($child1->id, $child2->id);
    is_deeply \@selected_ids, \@expected_ids, 'Correct children selected';
};

subtest 'Validation method tests' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data($db, { user_id => $parent->id });

    my $step = $workflow->get_step($db, { slug => 'select-children' });

    # Test add_child validation
    my $errors = $step->validate($db, {
        action => 'add_child',
        new_child_name => '',
        new_birth_date => '',
        new_emergency_name => '',
        new_emergency_phone => '',
    });

    ok $errors, 'Validation returns errors';
    is scalar(@$errors), 4, 'Four validation errors';

    # Test continue validation without selection
    $errors = $step->validate($db, {
        action => 'continue',
        # No children selected
    });

    ok $errors, 'Validation returns errors for continue without selection';
    like $errors->[0], qr/Please select at least one child/, 'Correct validation message';

    # Test continue validation with selection
    $errors = $step->validate($db, {
        action => 'continue',
        "child_" . $child1->id => 1,
    });

    ok !$errors, 'No validation errors with proper selection';
};

subtest 'HTMX response for add child' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data($db, { user_id => $parent->id });

    my $step = $workflow->get_step($db, { slug => 'select-children' });

    my $result = $step->process($db, {
        action => 'add_child',
        new_child_name => 'Diana Smith',
        new_birth_date => '2019-08-10',
        new_emergency_name => 'Emergency Contact',
        new_emergency_phone => '555-0123',
        'HX-Request' => '1',  # Simulate HTMX request
    });

    ok $result->{htmx_response}, 'HTMX response flag set';
    ok $result->{child}, 'Child object returned for HTMX';
    is $result->{child}->child_name, 'Diana Smith', 'Correct child returned';
};

done_testing;