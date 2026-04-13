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

subtest 'stay result forwards rendering data from "data" key' => sub {
    # Steps using the older next_step convention return rendering data
    # under 'data'.  The stay return must forward this as template_data
    # so the controller can render the step with the step's output.
    my $step_row = $dao->db->insert('workflow_steps', {
        workflow_id => $workflow->id,
        slug        => 'data-forward-test',
        description => 'Step for testing data forwarding',
        metadata    => undef,
        class       => 'Registry::DAO::WorkflowStep',
    }, { returning => '*' })->expand->hash;

    my $step = Registry::DAO::WorkflowStep->new(%$step_row);

    my $run = Registry::DAO::WorkflowRun->create($dao->db, {
        workflow_id    => $workflow->id,
        latest_step_id => $step->id,
        data           => '{}',
    });

    # Simulate a step returning next_step + data (the older convention)
    my $result = $run->process($dao->db, $step, {
        next_step => $step->id,
        data      => { pricing_plans => ['plan_a', 'plan_b'] },
    });

    ok $result->{stay}, 'Result has stay signal';
    ok $result->{template_data}, 'template_data is present in stay result';
    is ref($result->{template_data}), 'HASH', 'template_data is a hashref';
    is scalar @{$result->{template_data}{pricing_plans}}, 2,
       'Rendering data forwarded from "data" key to template_data';
};
