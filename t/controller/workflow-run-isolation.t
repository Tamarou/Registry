#!/usr/bin/env perl
# ABOUTME: Tests that workflow step processing uses the correct run under concurrency.
# ABOUTME: Verifies that two concurrent runs of the same workflow don't cross-contaminate data.

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::RunRecorderStep;
use Test::Registry::DB;

use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::WorkflowRun;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

# Create a workflow with a step that reads and writes run data
my $workflow = Registry::DAO::Workflow->create($dao->db, {
    name        => 'Isolation Test',
    slug        => 'isolation-test',
    description => 'Tests run data isolation',
    first_step  => 'step-one',
});

my $step_one = Registry::DAO::WorkflowStep->create($dao->db, {
    workflow_id => $workflow->id,
    slug        => 'step-one',
    description => 'First step',
    class       => 'Registry::DAO::WorkflowStep',
});

my $step_two = Registry::DAO::WorkflowStep->create($dao->db, {
    workflow_id => $workflow->id,
    slug        => 'step-two',
    description => 'Second step',
    class       => 'Registry::DAO::WorkflowStep',
    depends_on  => $step_one->id,
});

# ============================================================
# Test: Two concurrent runs maintain separate data
# ============================================================
subtest 'concurrent runs maintain separate data' => sub {
    # Create two runs with different data
    my $run_a = Registry::DAO::WorkflowRun->create($dao->db, {
        workflow_id => $workflow->id,
    });
    $run_a->update_data($dao->db, { user_name => 'Alice' });

    my $run_b = Registry::DAO::WorkflowRun->create($dao->db, {
        workflow_id => $workflow->id,
    });
    $run_b->update_data($dao->db, { user_name => 'Bob' });

    # Process step_one for run_a
    $run_a->process($dao->db, $step_one, { color => 'red' });

    # Process step_one for run_b
    $run_b->process($dao->db, $step_one, { color => 'blue' });

    # Reload runs
    ($run_a) = $dao->find(WorkflowRun => { id => $run_a->id });
    ($run_b) = $dao->find(WorkflowRun => { id => $run_b->id });

    # Each run should have its own data, not the other's
    is $run_a->data->{user_name}, 'Alice', 'Run A has Alice';
    is $run_b->data->{user_name}, 'Bob', 'Run B has Bob';
    is $run_a->data->{color}, 'red', 'Run A has red';
    is $run_b->data->{color}, 'blue', 'Run B has blue';
};

# ============================================================
# Test: Step receives correct run via process method
# ============================================================
subtest 'step process receives the correct run object' => sub {
    # Create a custom step class that records which run it sees
    # We can test this by checking that the base WorkflowStep::process
    # receives a run parameter when called from WorkflowRun::process

    my $run_a = Registry::DAO::WorkflowRun->create($dao->db, {
        workflow_id => $workflow->id,
    });
    $run_a->update_data($dao->db, { marker => 'run_a_marker' });

    my $run_b = Registry::DAO::WorkflowRun->create($dao->db, {
        workflow_id => $workflow->id,
    });
    $run_b->update_data($dao->db, { marker => 'run_b_marker' });

    # Process run_a's step -- the step should see run_a's data
    my $result_a = $run_a->process($dao->db, $step_one, {});

    # Process run_b's step -- the step should see run_b's data
    my $result_b = $run_b->process($dao->db, $step_one, {});

    # Verify the runs didn't cross-contaminate
    ($run_a) = $dao->find(WorkflowRun => { id => $run_a->id });
    ($run_b) = $dao->find(WorkflowRun => { id => $run_b->id });

    is $run_a->data->{marker}, 'run_a_marker', 'Run A marker preserved';
    is $run_b->data->{marker}, 'run_b_marker', 'Run B marker preserved';

};

# ============================================================
# Test: a step is handed ITS run, not the workflow's latest
# ============================================================
# This was `ok 1, 'Process mechanism verified (structural)'` under a comment
# explaining that a real test would need the drop workflow's steps and their
# enrollment data. It needs neither: a step class that records which run it was
# given is enough, and it is the whole mechanism under test.
#
# The failure it guards against is specific. Every step's process() signature is
# ($db, $form_data, $run = undef), and the fallback when $run is absent is
# `$self->workflow($db)->latest_run($db)`. Two runs of one workflow in flight
# means the latest belongs to whoever started most recently -- so a step that
# falls back writes one visitor's answers into another's registration.
subtest 'a step receives the run being processed, not the latest one' => sub {
    Registry::DAO::WorkflowStep->create($dao->db, {
        workflow_id => $workflow->id,
        slug        => 'recorder',
        description => 'Records the run it was handed',
        class       => 'Test::Registry::RunRecorderStep',
    });

    # Re-found, not used as created: create() blesses into the base class, and
    # find() is what loads the subclass named in the `class` column and blesses
    # into it. Using the created object silently ran the base step's process.
    my $recorder = Registry::DAO::WorkflowStep->find($dao->db, {
        workflow_id => $workflow->id, slug => 'recorder',
    });
    isa_ok $recorder, 'Test::Registry::RunRecorderStep';

    my $first = Registry::DAO::WorkflowRun->create($dao->db, {
        workflow_id => $workflow->id,
    });
    # Started second, so it is the one latest_run would return for both.
    my $latest = Registry::DAO::WorkflowRun->create($dao->db, {
        workflow_id => $workflow->id,
    });

    $first->process($dao->db, $recorder, {});
    $latest->process($dao->db, $recorder, {});

    ($first)  = $dao->find(WorkflowRun => { id => $first->id });
    ($latest) = $dao->find(WorkflowRun => { id => $latest->id });

    is $first->data->{seen_run_id}, $first->id,
        'the earlier run was processed as itself';
    is $latest->data->{seen_run_id}, $latest->id,
        'and so was the later one';
    isnt $first->data->{seen_run_id}, $latest->id,
        'the earlier run did not get the later one -- which is the bug';
};

done_testing;
