#!/usr/bin/env perl
# ABOUTME: Controller-level tests for the AccountCheck workflow step with passwordless auth
# ABOUTME: Validates redirect behavior, account creation, and session continuity via the step class

use 5.42.0;
use warnings;
use utf8;
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

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
    slug => 'test_enroll_accheck',
});

# Switch to tenant schema
$db->schema($tenant->slug);

# Create test user (passwordless - no password field)
my $test_user = Registry::DAO::User->create($db, {
    username  => 'testparent',
    name      => 'Test Parent',
    email     => 'parent@test.com',
    user_type => 'parent',
});

# Create test workflow
my $workflow = Registry::DAO::Workflow->create($db, {
    slug        => 'summer-camp-registration',
    name        => 'Summer Camp Registration',
    description => 'Registration workflow for summer camp programs with account creation',
    first_step  => 'landing',
});

# Create workflow steps
my $landing_step = Registry::DAO::WorkflowStep->create($db, {
    workflow_id => $workflow->id,
    slug        => 'landing',
    description => 'Welcome Page',
    class       => 'Registry::DAO::WorkflowStep',
});

my $account_check_step = Registry::DAO::WorkflowStep->create($db, {
    workflow_id => $workflow->id,
    slug        => 'account-check',
    description => 'Account Check',
    class       => 'Registry::DAO::WorkflowSteps::AccountCheck',
    depends_on  => $landing_step->id,
});

my $camper_info_step = Registry::DAO::WorkflowStep->create($db, {
    workflow_id => $workflow->id,
    slug        => 'camper-info',
    description => 'Camper Information',
    class       => 'Registry::DAO::WorkflowStep',
    depends_on  => $account_check_step->id,
});

sub make_step {
    return Registry::DAO::WorkflowSteps::AccountCheck->new(
        id          => $account_check_step->id,
        workflow_id => $workflow->id,
        slug        => 'account-check',
        description => 'Account Check',
        class       => 'Registry::DAO::WorkflowSteps::AccountCheck',
    );
}

subtest 'Account check step - first visit' => sub {
    my $run  = $workflow->new_run($db);
    my $step = make_step();

    # Process with no action - should stay on step
    my $result = $step->process($db, {});
    ok($result->{stay}, 'Stays on step when no action provided');
};

subtest 'Login action redirects to auth controller' => sub {
    my $run  = $workflow->new_run($db);
    my $step = make_step();

    # Process login action - passwordless: must redirect to /auth/login
    my $result = $step->process($db, {
        action   => 'login',
        username => 'testparent',
    });

    ok($result->{redirect},            'Login action returns a redirect');
    is($result->{redirect}, '/auth/login', 'Redirect target is /auth/login');
    ok(!$result->{stay},   'Does not stay on step');
    ok(!$result->{errors}, 'No errors returned');
};

subtest 'Login action redirects regardless of credentials supplied' => sub {
    my $run  = $workflow->new_run($db);
    my $step = make_step();

    # Even with no username, should redirect (auth controller validates)
    my $result = $step->process($db, { action => 'login' });

    ok($result->{redirect},            'Login with no data still redirects');
    is($result->{redirect}, '/auth/login', 'Redirect target is /auth/login');
};

subtest 'Create account action creates user and redirects to magic-link-sent' => sub {
    my $run  = $workflow->new_run($db);
    my $step = make_step();

    my $result = $step->process($db, {
        action   => 'create_account',
        username => 'newparent',
        email    => 'newparent@test.com',
        name     => 'New Parent',
    });

    ok($result->{redirect},                         'create_account returns redirect');
    like($result->{redirect}, qr{magic-link-sent},  'Redirect goes to magic-link-sent page');

    # Verify user was created
    my $user = Registry::DAO::User->find($db, { username => 'newparent' });
    ok($user,                   'User was created');
    is($user->email, 'newparent@test.com', 'User has correct email');
    ok(!$user->passhash,        'User has no password hash (passwordless)');
};

subtest 'Continue when already logged in' => sub {
    my $run  = $workflow->new_run($db);
    my $step = make_step();

    # Set user in run data (simulating logged in state)
    $run->update_data($db, {
        user_id    => $test_user->id,
        user_name  => 'Test Parent',
        user_email => 'parent@test.com',
    });

    # Process continue action
    my $result = $step->process($db, {
        action  => 'continue_logged_in',
        user_id => $test_user->id,
    });

    is($result->{next_step}, 'camper-info', 'Moves to next step when already logged in');
};

subtest 'Validation checks for create_account but not login' => sub {
    my $step = make_step();

    # login action requires no fields
    my $errors = $step->validate($db, { action => 'login' });
    ok(!$errors, 'No errors for login without credentials (passwordless)');

    # create_account requires email and username
    $errors = $step->validate($db, { action => 'create_account' });
    ok($errors && $errors->{errors}, 'Validation errors for create_account without fields');

    $errors = $step->validate($db, {
        action => 'create_account', email => 'a@b.com', username => 'test',
    });
    ok(!$errors, 'No errors for create_account with required fields');

    # No action requires no fields
    $errors = $step->validate($db, {});
    ok(!$errors, 'No validation errors for empty form data');
};

done_testing;
