#!/usr/bin/env perl
# ABOUTME: Tests that AccountCheck properly completes continuations after user creation.
# ABOUTME: Validates #155 -- continuation_id is cleared so the step doesn't re-trigger.

use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw(done_testing is ok subtest)];
defer { done_testing };

use Test::Registry::DB;
use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::WorkflowRun;
use Registry::DAO::WorkflowSteps::AccountCheck;

my $test_db = Test::Registry::DB->new;
my $dao = $test_db->db;

$dao->import_workflows(['workflows/tenant-signup.yml']);

my $workflow = $dao->find('Registry::DAO::Workflow', { slug => 'tenant-signup' });
ok $workflow, 'Found workflow';

subtest 'AccountCheck clears continuation_id after processing' => sub {
    # Create a "child" continuation run that simulates user creation
    my $child_run = Registry::DAO::WorkflowRun->create($dao->db, {
        workflow_id => $workflow->id,
        data        => '{"user_id": "test-user-123", "user_name": "Test User", "user_email": "test@example.com"}',
    });
    ok $child_run, 'Created child continuation run';

    # Create the "parent" run that has a continuation pointing to the child
    my $parent_run = Registry::DAO::WorkflowRun->create($dao->db, {
        workflow_id    => $workflow->id,
        continuation_id => $child_run->id,
        data           => '{}',
    });
    ok $parent_run, 'Created parent run with continuation';
    ok $parent_run->has_continuation, 'Parent run has continuation';

    # Create an AccountCheck step
    my $step_row = $dao->db->insert('workflow_steps', {
        workflow_id => $workflow->id,
        slug        => 'account-check-test',
        description => 'Test account check step',
        metadata    => undef,
        class       => 'Registry::DAO::WorkflowSteps::AccountCheck',
    }, { returning => '*' })->expand->hash;

    my $step = Registry::DAO::WorkflowSteps::AccountCheck->new(%$step_row);
    ok $step, 'Created AccountCheck step';

    # Process the step -- it should detect the continuation and clear it
    my $result = $step->process($dao->db, {}, $parent_run);

    # The step should have advanced (user was found in continuation data)
    ok !$result->{stay}, 'Step did not stay (continuation was processed)';

    # Re-read the parent run -- continuation_id should be cleared
    my $updated_run = Registry::DAO::WorkflowRun->find($dao->db, { id => $parent_run->id });
    ok !$updated_run->has_continuation,
       'continuation_id cleared after processing';
};
