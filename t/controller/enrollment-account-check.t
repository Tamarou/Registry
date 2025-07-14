#!/usr/bin/env perl
use v5.34.0;
use warnings;
use utf8;
use experimental qw(signatures);

use Test::More;
use Test::Mojo;

use lib qw(lib t/lib);
use Test::Registry::DB;
use Test::Registry::Fixtures;

use Registry;
use Registry::DAO::WorkflowSteps::AccountCheck;
use Mojo::JSON qw(encode_json);

# Setup test database
my $t_db = Test::Registry::DB->new;
my $db = $t_db->db;

# Create test app
my $t = Test::Mojo->new('Registry');
$t->app->helper(dao => sub { $db });

# Create test tenant
my $tenant = Test::Registry::Fixtures::create_tenant($db, {
    name => 'Test Organization',
    slug => 'test-org',
});

# Switch to tenant schema
$db->schema($tenant->slug);

# Create test user
my $test_user = Registry::DAO::User->create($db, {
    username => 'testparent',
    password => 'testpass123',
    name => 'Test Parent',
    email => 'parent@test.com',
    user_type => 'parent',
});

# Create test workflow
my $workflow = Registry::DAO::Workflow->create($db, {
    slug => 'summer-camp-registration-enhanced',
    name => 'Summer Camp Registration (Enhanced)',
    description => 'Enhanced registration with account creation',
    first_step => 'landing',
});

# Create workflow steps
my $landing_step = Registry::DAO::WorkflowStep->create($db, {
    workflow_id => $workflow->id,
    slug => 'landing',
    description => 'Welcome Page',
    class => 'Registry::DAO::WorkflowStep',
});

my $account_check_step = Registry::DAO::WorkflowStep->create($db, {
    workflow_id => $workflow->id,
    slug => 'account-check',
    description => 'Account Check',
    class => 'Registry::DAO::WorkflowSteps::AccountCheck',
    depends_on => $landing_step->id,
});

my $camper_info_step = Registry::DAO::WorkflowStep->create($db, {
    workflow_id => $workflow->id,
    slug => 'camper-info',
    description => 'Camper Information',
    class => 'Registry::DAO::WorkflowStep',
    depends_on => $account_check_step->id,
});

subtest 'Account check step - first visit' => sub {
    my $run = $workflow->new_run($db);
    my $step = Registry::DAO::WorkflowSteps::AccountCheck->new(
        id => $account_check_step->id,
        workflow_id => $workflow->id,
        slug => 'account-check',
        description => 'Account Check',
        class => 'Registry::DAO::WorkflowSteps::AccountCheck',
    );
    
    # Process with no action - should stay on step
    my $result = $step->process($db, {});
    ok($result->{stay}, 'Stays on step when no action provided');
};

subtest 'Login with valid credentials' => sub {
    my $run = $workflow->new_run($db);
    my $step = Registry::DAO::WorkflowSteps::AccountCheck->new(
        id => $account_check_step->id,
        workflow_id => $workflow->id,
        slug => 'account-check',
        description => 'Account Check',
        class => 'Registry::DAO::WorkflowSteps::AccountCheck',
    );
    
    # Process login
    my $result = $step->process($db, {
        action => 'login',
        username => 'testparent',
        password => 'testpass123',
    });
    
    is($result->{next_step}, 'camper-info', 'Moves to next step on successful login');
    
    # Check run data was updated
    $run = Registry::DAO::WorkflowRun->find($db, { id => $run->id });
    is($run->data->{user_id}, $test_user->id, 'User ID stored in run data');
    is($run->data->{user_name}, 'Test Parent', 'User name stored in run data');
    is($run->data->{user_email}, 'parent@test.com', 'User email stored in run data');
};

subtest 'Login with invalid credentials' => sub {
    my $run = $workflow->new_run($db);
    my $step = Registry::DAO::WorkflowSteps::AccountCheck->new(
        id => $account_check_step->id,
        workflow_id => $workflow->id,
        slug => 'account-check',
        description => 'Account Check',
        class => 'Registry::DAO::WorkflowSteps::AccountCheck',
    );
    
    # Process login with wrong password
    my $result = $step->process($db, {
        action => 'login',
        username => 'testparent',
        password => 'wrongpass',
    });
    
    ok($result->{stay}, 'Stays on step with invalid credentials');
    ok($result->{errors}, 'Returns errors');
    like($result->{errors}[0], qr/Invalid/, 'Error mentions invalid credentials');
};

subtest 'Create account continuation' => sub {
    my $run = $workflow->new_run($db);
    
    # Add enrollment data to run
    $run->update_data($db, {
        session_id => 'test-session-123',
        location_id => 'test-location-456',
    });
    
    my $step = Registry::DAO::WorkflowSteps::AccountCheck->new(
        id => $account_check_step->id,
        workflow_id => $workflow->id,
        slug => 'account-check',
        description => 'Account Check',
        class => 'Registry::DAO::WorkflowSteps::AccountCheck',
    );
    
    # Process create account action
    my $result = $step->process($db, {
        action => 'create_account',
    });
    
    is($result->{continuation}, 'user-creation', 'Starts user-creation continuation');
    ok($result->{continuation_data}, 'Has continuation data');
    is($result->{continuation_data}{return_to}, 'summer-camp-registration-enhanced', 
       'Continuation knows where to return');
    is($result->{continuation_data}{enrollment_data}{session_id}, 'test-session-123',
       'Preserves enrollment data');
};

subtest 'Return from user creation continuation' => sub {
    # Clean up any previous runs to ensure latest_run returns our run
    $db->db->delete('workflow_runs', { workflow_id => $workflow->id });
    
    my $run = $workflow->new_run($db);
    
    # Create a user-creation workflow for the continuation
    my $user_creation_workflow = Registry::DAO::Workflow->create($db, {
        name => 'User Creation',
        slug => 'user-creation',
        description => 'User creation workflow'
    });
    
    # Simulate a continuation that created a user (from user-creation workflow)
    my $continuation = Registry::DAO::WorkflowRun->create($db, {
        workflow_id => $user_creation_workflow->id,
        data => encode_json({
            user_id => $test_user->id,
            user_name => 'Test Parent',
            user_email => 'parent@test.com',
            enrollment_data => {
                session_id => 'preserved-session-123',
            }
        })
    });
    
    # Update run to have continuation
    $db->db->update('workflow_runs', 
        { continuation_id => $continuation->id },
        { id => $run->id }
    );
    
    # Refresh run object
    $run = Registry::DAO::WorkflowRun->find($db, { id => $run->id });
    
    my $step = Registry::DAO::WorkflowSteps::AccountCheck->new(
        id => $account_check_step->id,
        workflow_id => $workflow->id,
        slug => 'account-check',
        description => 'Account Check',
        class => 'Registry::DAO::WorkflowSteps::AccountCheck',
    );
    
    # Process without action (returning from continuation)
    my $result = $step->process($db, {});
    
    is($result->{next_step}, 'camper-info', 'Moves to next step after continuation');
    
    # Check run data was updated
    $run = Registry::DAO::WorkflowRun->find($db, { id => $run->id });
    is($run->data->{user_id}, $test_user->id, 'User ID stored from continuation');
    is($run->data->{session_id}, 'preserved-session-123', 'Enrollment data preserved');
};

subtest 'Continue when already logged in' => sub {
    my $run = $workflow->new_run($db);
    
    # Set user in run data (simulating logged in state)
    $run->update_data($db, {
        user_id => $test_user->id,
        user_name => 'Test Parent',
        user_email => 'parent@test.com',
    });
    
    my $step = Registry::DAO::WorkflowSteps::AccountCheck->new(
        id => $account_check_step->id,
        workflow_id => $workflow->id,
        slug => 'account-check',
        description => 'Account Check',
        class => 'Registry::DAO::WorkflowSteps::AccountCheck',
    );
    
    # Process continue action
    my $result = $step->process($db, {
        action => 'continue_logged_in',
        user_id => $test_user->id,
    });
    
    is($result->{next_step}, 'camper-info', 'Moves to next step when already logged in');
};

subtest 'Validation' => sub {
    my $step = Registry::DAO::WorkflowSteps::AccountCheck->new(
        id => $account_check_step->id,
        workflow_id => $workflow->id,
        slug => 'account-check',
        description => 'Account Check',
        class => 'Registry::DAO::WorkflowSteps::AccountCheck',
    );
    
    # Test login validation
    my $errors = $step->validate($db, { action => 'login' });
    ok($errors, 'Returns errors for login without credentials');
    is(@$errors, 2, 'Two errors for missing username and password');
    
    # Test valid login
    $errors = $step->validate($db, {
        action => 'login',
        username => 'test',
        password => 'test',
    });
    ok(!$errors, 'No errors with complete login data');
    
    # Test other actions don't require validation
    $errors = $step->validate($db, { action => 'create_account' });
    ok(!$errors, 'No validation required for create account');
};

done_testing;