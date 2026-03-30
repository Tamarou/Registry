#!/usr/bin/env perl
# ABOUTME: Tests for AccountCheck workflow step with passwordless auth
# ABOUTME: Validates redirect-based login, magic-link-based account creation, and session continuity
use 5.42.0;
use warnings;
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::User;
use Registry::DAO::MagicLinkToken;
use Registry::DAO::WorkflowSteps::AccountCheck;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

# Create test tenant and set up schema
my $tenant = Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Test AccountCheck Passwordless Tenant',
    slug => 'test_ac_passwordless',
});

# Switch to tenant schema
$dao = Registry::DAO->new(url => $test_db->uri, schema => 'test_ac_passwordless');
my $db = $dao->db;

# Create workflow
my $workflow = Registry::DAO::Workflow->create($db, {
    name => 'Test AccountCheck Workflow',
    slug => 'test-accountcheck-workflow',
    description => 'Test workflow for AccountCheck passwordless',
    first_step => 'account-check',
});

# Create account-check step
my $account_check_step_data = Registry::DAO::WorkflowStep->create($db, {
    workflow_id => $workflow->id,
    slug        => 'account-check',
    class       => 'Registry::DAO::WorkflowSteps::AccountCheck',
    description => 'Account Check Step',
});

# Create a next step so next_step() returns something
my $next_step_data = Registry::DAO::WorkflowStep->create($db, {
    workflow_id => $workflow->id,
    slug        => 'next-step',
    class       => 'Registry::DAO::WorkflowStep',
    description => 'Next Step',
    depends_on  => $account_check_step_data->id,
});

# Update workflow to set first_step
$workflow->update($db, { first_step => 'account-check' }, { id => $workflow->id });

# Create a test user (no password - passwordless)
my $test_user = Registry::DAO::User->create($db, {
    username  => 'testuser_passwordless',
    email     => 'passwordless@example.com',
    name      => 'Passwordless User',
    user_type => 'parent',
});

# Helper to get the AccountCheck step object
sub get_step {
    return Registry::DAO::WorkflowSteps::AccountCheck->new(
        id          => $account_check_step_data->id,
        workflow_id => $workflow->id,
        slug        => 'account-check',
        description => 'Account Check Step',
        class       => 'Registry::DAO::WorkflowSteps::AccountCheck',
    );
}

subtest 'login action returns redirect to /auth/login' => sub {
    my $run  = $workflow->new_run($db);
    my $step = get_step();

    my $result = $step->process($db, { action => 'login' });

    ok $result->{redirect}, 'login action returns a redirect';
    is $result->{redirect}, '/auth/login', 'redirect target is /auth/login';
    ok !$result->{stay},     'does not stay on step';
    ok !$result->{errors},   'no errors';
};

subtest 'login action does not require a password' => sub {
    my $run  = $workflow->new_run($db);
    my $step = get_step();

    # Even with username and no password, should redirect
    my $result = $step->process($db, {
        action   => 'login',
        username => 'testuser_passwordless',
    });

    ok $result->{redirect}, 'returns redirect even without password';
    is $result->{redirect}, '/auth/login', 'redirect target is /auth/login';
};

subtest 'create_account creates user without password and generates magic link token' => sub {
    my $run  = $workflow->new_run($db);
    my $step = get_step();

    my $result = $step->process($db, {
        action   => 'create_account',
        email    => 'newuser@example.com',
        username => 'newuser_passwordless',
        name     => 'New User',
    });

    ok $result->{redirect}, 'create_account returns a redirect';
    like $result->{redirect}, qr{magic-link-sent}, 'redirect goes to magic-link-sent page';

    # Verify user was created in the database
    my $user = Registry::DAO::User->find($db, { username => 'newuser_passwordless' });
    ok $user, 'user was created in database';
    is $user->email, 'newuser@example.com', 'user has correct email';

    # Verify user has no password hash
    ok !$user->passhash, 'user was created without a password hash';

    # Verify a magic link token was generated for this user with purpose 'login'
    my $tokens = $db->select('magic_link_tokens', '*', {
        user_id => $user->id,
        purpose => 'login',
    })->hashes->to_array;

    ok scalar(@$tokens) > 0, 'magic link token was generated for new user';
    ok !$tokens->[0]{consumed_at}, 'token is not yet consumed';
};

subtest 'create_account does not require password in form data' => sub {
    my $run  = $workflow->new_run($db);
    my $step = get_step();

    # Should succeed without a password field
    my $result = $step->process($db, {
        action   => 'create_account',
        email    => 'another@example.com',
        username => 'another_user',
        name     => 'Another User',
    });

    ok $result->{redirect}, 'create_account succeeds without password field';
    ok !$result->{errors},  'no errors without password field';
};

subtest 'continue_logged_in moves to next step when user_id is valid' => sub {
    my $run  = $workflow->new_run($db);
    my $step = get_step();

    $run->update_data($db, {
        user_id    => $test_user->id,
        user_name  => $test_user->name,
        user_email => $test_user->email,
    });

    my $result = $step->process($db, {
        action  => 'continue_logged_in',
        user_id => $test_user->id,
    });

    ok $result->{next_step}, 'continue_logged_in moves to next step';
    is $result->{next_step}, 'next-step', 'correct next step slug returned';
    ok !$result->{stay},     'does not stay on step';
};

subtest 'continue_logged_in stays when user_id is missing' => sub {
    my $run  = $workflow->new_run($db);
    my $step = get_step();

    my $result = $step->process($db, {
        action => 'continue_logged_in',
    });

    ok $result->{stay}, 'stays on step when no user_id';
};

subtest 'validate() does not require password field for login action' => sub {
    my $step = get_step();

    # login action with username only - should not error about password
    my $errors = $step->validate($db, {
        action   => 'login',
        username => 'testuser_passwordless',
    });

    ok !$errors, 'no validation errors for login with only username';
};

subtest 'validate() does not require any fields for login action' => sub {
    my $step = get_step();

    # Even with empty login action - no password required
    my $errors = $step->validate($db, { action => 'login' });

    ok !$errors, 'no validation errors for login action without any fields';
};

subtest 'validate() requires email and username for create_account action' => sub {
    my $step = get_step();

    my $errors = $step->validate($db, { action => 'create_account' });
    ok $errors && $errors->{errors}, 'validation errors returned for empty create_account';

    my $valid = $step->validate($db, {
        action   => 'create_account',
        email    => 'test@example.com',
        username => 'testuser',
    });
    ok !$valid, 'no validation errors when email and username provided';
};

subtest 'first visit with no action stays on step' => sub {
    my $run  = $workflow->new_run($db);
    my $step = get_step();

    my $result = $step->process($db, {});

    ok $result->{stay}, 'stays on step when no action';
};

done_testing;
