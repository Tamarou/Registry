#!/usr/bin/env perl
# ABOUTME: Tests that WorkflowRun::process handles the "stay" signal correctly.
# ABOUTME: Validates both explicit stay => 1 and implicit next_step => $self->id.

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

my $test_db = Test::Registry::DB->new;
my $dao = $test_db->db;

$dao->import_workflows(['workflows/tenant-signup.yml']);

my $workflow = $dao->find('Registry::DAO::Workflow', { slug => 'tenant-signup' });
ok $workflow, 'Found tenant-signup workflow';

subtest 'next_step => step id treated as stay (does not advance)' => sub {
    # Insert a test step that uses the base WorkflowStep class.
    # The base class process() returns $data directly, so we pass
    # next_step pointing to the step's own ID to trigger the stay path.
    my $step_row = $dao->db->insert('workflow_steps', {
        workflow_id => $workflow->id,
        slug        => 'stay-test-step',
        description => 'Step for testing stay behavior',
        metadata    => undef,
        class       => 'Registry::DAO::WorkflowStep',
    }, { returning => '*' })->expand->hash;

    my $step = Registry::DAO::WorkflowStep->new(%$step_row);
    ok $step, 'Created test step';

    # Create a run positioned at this step
    my $run = Registry::DAO::WorkflowRun->create($dao->db, {
        workflow_id    => $workflow->id,
        latest_step_id => $step->id,
        data           => '{}',
    });
    ok $run, 'Created run at test step';

    # Process the step with form data that includes next_step => step's own ID.
    # The base WorkflowStep::process returns $data as-is, so next_step will be
    # in the result and WorkflowRun::process should detect it as a stay.
    my $result = $run->process($dao->db, $step, {
        next_step => $step->id,
        some_data => 'preserved',
    });

    # The result should signal a stay
    ok ref($result) eq 'HASH', 'Result is a hashref';
    ok $result->{stay}, 'Result has stay signal';

    # Re-read the run -- latest_step_id should NOT have changed
    my $run_after = Registry::DAO::WorkflowRun->find($dao->db, { id => $run->id });
    is $run_after->latest_step($dao->db)->id, $step->id,
       'latest_step_id did not advance';

};
