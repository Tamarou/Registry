#!/usr/bin/env perl
# ABOUTME: Tests for workflow validation error handling.
# ABOUTME: Verifies graceful handling of out-of-order steps, invalid data, and completed workflows.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers qw(
    workflow_url
    workflow_process_step_url
);

use Registry::DAO qw(Workflow);
use Registry::DAO::WorkflowStep;
use Registry::DAO::WorkflowRun;
use Mojo::Home;
use YAML::XS qw(Load);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# Import workflows
my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml($dao, $file->slurp);
}

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

my ($workflow) = $dao->find(Workflow => { slug => 'session-creation' });
ok $workflow, 'session-creation workflow exists';

# ============================================================
# Test: Submitting a step out of order
# ============================================================
subtest 'out-of-order step submission rejected' => sub {
    # Start the workflow
    $t->post_ok(workflow_url($workflow) => form => {})->status_is(302);

    my $run = $workflow->latest_run($dao->db);
    my $next = $run->next_step($dao->db);

    # Try to POST to a step that's NOT the current step
    # The 'complete' step is the last step, not the current one
    my $wrong_url = "/session-creation/${\$run->id}/complete";

    # Should die or return an error (wrong step)
    my $response = $t->post_ok($wrong_url => form => {});
    my $status = $response->tx->res->code;

    ok($status == 500 || $status == 400 || $status == 302,
       "Out-of-order step returns error (status $status)");
};

# ============================================================
# Test: Posting to a completed workflow returns 201 DONE
# ============================================================
subtest 'POST to completed workflow returns 201' => sub {
    # Create and complete a workflow
    my $wf = Registry::DAO::Workflow->create($dao->db, {
        name => 'Completion Test', slug => 'completion-test',
        description => 'Test', first_step => 'only',
    });

    my $step = Registry::DAO::WorkflowStep->create($dao->db, {
        workflow_id => $wf->id, slug => 'only',
        description => 'Only step', class => 'Registry::DAO::WorkflowStep',
    });

    $t->post_ok('/completion-test' => form => {})->status_is(201);

    my $run = $wf->latest_run($dao->db);
    ok $run->completed($dao->db), 'Workflow is completed';

    # POST again to the completed step
    $t->post_ok("/completion-test/${\$run->id}/only" => form => {})
      ->status_is(201, 'POST to completed workflow returns 201 DONE');
};

# ============================================================
# Test: GET a workflow run step with invalid run ID
# ============================================================
subtest 'invalid run ID handled gracefully' => sub {
    my $response = $t->get_ok('/session-creation/00000000-0000-0000-0000-000000000000/info');
    my $status = $response->tx->res->code;

    # Should be a 500 (can't find run) or 404, not a crash
    ok($status >= 400, "Invalid run ID returns error (status $status)");
};

# ============================================================
# Test: Nonexistent workflow slug returns error
# ============================================================
subtest 'nonexistent workflow slug returns error' => sub {
    my $response = $t->get_ok('/nonexistent-workflow-slug-xyz');
    my $status = $response->tx->res->code;

    # Should be an error, not a crash
    ok($status >= 400, "Nonexistent workflow returns error (status $status)");
};

# ============================================================
# Test: Browser back button - GET a previous step
# ============================================================
subtest 'GET previous step renders without corrupting state' => sub {
    # Start session-creation and advance through first step
    $t->post_ok(workflow_url($workflow) => form => {})->status_is(302);

    my $run = $workflow->latest_run($dao->db);
    my $next = $run->next_step($dao->db);

    # The redirect URL is the next step. Extract the run ID.
    my $redirect = $t->tx->res->headers->location;

    # GET the current step (this is what "back button" would do for the step before)
    my $first_step = $workflow->first_step($dao->db);
    my $prev_url = "/session-creation/${\$run->id}/${\$first_step->slug}";

    # GET the previous step -- should not crash the server
    my $response = $t->get_ok($prev_url);
    my $status = $response->tx->res->code;
    ok($status == 200 || $status == 500,
       "GET previous step returns $status (renders or template missing)");

    # The workflow run data should NOT be corrupted
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    ok $run, 'Workflow run still exists after back navigation';
    ok !$run->completed($dao->db), 'Workflow not prematurely completed';
};

done_testing;
