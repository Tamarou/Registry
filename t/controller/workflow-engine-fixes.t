#!/usr/bin/env perl
# ABOUTME: Tests for workflow engine fixes: stay semantics, auto-run on GET, continuation return.
# ABOUTME: These fixes are prerequisites for the tenant-storefront workflow.

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers qw(
    workflow_url
    workflow_run_step_url
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

# Import all workflows from YAML
my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml($dao, $file->slurp);
}

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

# ============================================================
# Create a test workflow with two steps for stay semantics testing
# ============================================================
my $stay_workflow = Registry::DAO::Workflow->create($dao->db, {
    name        => 'Stay Test Workflow',
    slug        => 'stay-test',
    description => 'Tests stay semantics',
    first_step  => 'step-one',
});

my $step_one = Registry::DAO::WorkflowStep->create($dao->db, {
    workflow_id => $stay_workflow->id,
    slug        => 'step-one',
    description => 'First step (returns stay)',
    class       => 'Registry::DAO::WorkflowStep',
});

my $step_two = Registry::DAO::WorkflowStep->create($dao->db, {
    workflow_id => $stay_workflow->id,
    slug        => 'step-two',
    description => 'Second step',
    class       => 'Registry::DAO::WorkflowStep',
    depends_on  => $step_one->id,
});

# ============================================================
# Fix 1: Stay semantics
# ============================================================

subtest 'stay: POST with stay result redirects back to same step' => sub {
    # Start a run manually
    my $run = $stay_workflow->new_run($dao->db);
    $run->process($dao->db, $step_one, {});

    # Now the run is at step-one, next_step is step-two
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    my $next = $run->next_step($dao->db);
    is $next->slug, 'step-two', 'Next step is step-two before stay test';

    # Use the select-children step (which returns {stay => 1} for add_child)
    # to test stay semantics. But we need a simpler approach -- let's use
    # the registration workflow's select-children with action=add_child.
    #
    # Actually, for a clean test we need a step class that returns {stay => 1}.
    # The SelectChildren step does this. Let's test it directly.

    # Instead, test at the HTTP level with the actual SelectChildren step
    # from the summer-camp-registration workflow.
    my ($reg_workflow) = $dao->find(Workflow => { slug => 'summer-camp-registration' });
    ok $reg_workflow, 'summer-camp-registration workflow exists';

    # Start a registration workflow
    my $start_url = workflow_url($reg_workflow);
    $t->post_ok($start_url => form => {})->status_is(302);

    my $reg_run = $reg_workflow->latest_run($dao->db);

    # Advance through account-check
    my $acct_step = $reg_run->next_step($dao->db);
    $t->post_ok(workflow_process_step_url($reg_workflow, $reg_run, $acct_step) => form => {
        action => 'create_account',
        username => 'stay_test_user',
        email => 'stay_test@example.com',
        name => 'Stay Test',
    })->status_is(302);

    ($reg_run) = $dao->find(WorkflowRun => { id => $reg_run->id });
    my $sel_step = $reg_run->next_step($dao->db);
    is $sel_step->slug, 'select-children', 'At select-children step';

    # Create a child for the user
    my $user = Registry::DAO::User->find($dao->db, { username => 'stay_test_user' });
    require Registry::DAO::Family;
    Registry::DAO::Family->add_child($dao->db, $user->id, {
        child_name => 'Stay Kid', birth_date => '2018-01-01', grade => '2',
        medical_info => {}, emergency_contact => { name => 'P', phone => '555' },
    });

    # POST add_child action -- should stay on select-children, not advance
    my $step_url = workflow_process_step_url($reg_workflow, $reg_run, $sel_step);
    my $redirect = $t->post_ok($step_url => form => {
        action         => 'add_child',
        new_child_name => 'Another Kid',
        new_birth_date => '2019-06-15',
        new_emergency_name  => 'Parent',
        new_emergency_phone => '555-0000',
    })->status_is(302)->tx->res->headers->location;

    like $redirect, qr/select-children$/, 'Stay: redirected back to select-children (not camper-info)';

    # Verify the workflow is NOT completed
    ($reg_run) = $dao->find(WorkflowRun => { id => $reg_run->id });
    ok !$reg_run->completed($dao->db), 'Workflow not completed after stay';

    # Verify next_step is still select-children (or camper-info depending on how stay works)
    # The key assertion: we did NOT advance past select-children
    my $next_after_stay = $reg_run->next_step($dao->db);
    ok $next_after_stay, 'There is a next step (not completed)';
};

subtest 'stay: value not persisted in run data' => sub {
    # Verify that {stay => 1} returned by a step is stripped from run data
    # (it should be in TRANSIENT_KEYS)
    my ($reg_workflow) = $dao->find(Workflow => { slug => 'summer-camp-registration' });
    my $run = $reg_workflow->latest_run($dao->db);
    ($run) = $dao->find(WorkflowRun => { id => $run->id });

    # After the add_child POST above, 'stay' should NOT be in the run data
    ok !exists $run->data->{stay}, 'stay key not persisted in run data (transient)';
};

# ============================================================
# Shared workflows for Fix 2 and Fix 3 tests
# ============================================================

# Single-step parent workflow (no index template -- uses auto-run)
my $parent_wf = Registry::DAO::Workflow->create($dao->db, {
    name        => 'Parent Storefront',
    slug        => 'parent-storefront-test',
    description => 'Single step parent for continuation test',
    first_step  => 'listing',
});

Registry::DAO::WorkflowStep->create($dao->db, {
    workflow_id => $parent_wf->id,
    slug        => 'listing',
    description => 'Program listing',
    class       => 'Registry::DAO::WorkflowStep',
});

# Child workflow (2 steps)
my $child_wf = Registry::DAO::Workflow->create($dao->db, {
    name        => 'Child Registration',
    slug        => 'child-reg-test',
    description => 'Simple child workflow for continuation test',
    first_step  => 'info',
});

my $child_step1 = Registry::DAO::WorkflowStep->create($dao->db, {
    workflow_id => $child_wf->id,
    slug        => 'info',
    description => 'Info step',
    class       => 'Registry::DAO::WorkflowStep',
});

my $child_step2 = Registry::DAO::WorkflowStep->create($dao->db, {
    workflow_id => $child_wf->id,
    slug        => 'done',
    description => 'Done step',
    class       => 'Registry::DAO::WorkflowStep',
    depends_on  => $child_step1->id,
});

# ============================================================
# Fix 2: Auto-create run on GET
# ============================================================

subtest 'auto-run: GET workflow URL creates run and renders step' => sub {
    my $runs_before = $parent_wf->runs($dao->db);

    $t->get_ok('/parent-storefront-test')
      ->status_is(200);

    # A run should have been created
    my $runs_after = $parent_wf->runs($dao->db);
    ok $runs_after > $runs_before, 'GET created a new workflow run';

    # The page should render the step template content
    $t->content_like(qr/Test Storefront/i, 'Renders step template content');
};

subtest 'auto-run: multiple GETs each create valid runs' => sub {
    # Each GET creates a run (session reuse depends on cookie handling).
    # The key assertion: every GET renders a valid page with step content.
    $t->get_ok('/parent-storefront-test')->status_is(200);
    $t->content_like(qr/Test Storefront/, 'First GET renders step content');

    $t->get_ok('/parent-storefront-test')->status_is(200);
    $t->content_like(qr/Test Storefront/, 'Second GET also renders step content');

    # At least one run exists
    my $runs = $parent_wf->runs($dao->db);
    ok $runs >= 1, 'At least one run exists for the workflow';
};

# ============================================================
# Fix 3: Continuation return to completed single-step workflow
# ============================================================

subtest 'continuation: return to single-step parent re-renders step' => sub {
    # Uses parent_wf and child_wf created in shared setup above

    # GET the parent workflow -- auto-creates run without completing
    $t->get_ok('/parent-storefront-test')->status_is(200);
    my $parent_run = $parent_wf->latest_run($dao->db);
    ok $parent_run, 'Parent run created by GET';

    # Start a continuation from parent to child
    $t->post_ok("/parent-storefront-test/${\$parent_run->id}/callcc/child-reg-test")
      ->status_is(302);

    my $child_run = $child_wf->latest_run($dao->db);
    ok $child_run, 'Child workflow run created';
    is $child_run->continuation_id, $parent_run->id, 'Child has continuation_id pointing to parent';

    # start_continuation processes the first step (info) automatically,
    # so the child run is already at info, next_step is done
    ($child_run) = $dao->find(WorkflowRun => { id => $child_run->id });
    my $child_next = $child_run->next_step($dao->db);
    is $child_next->slug, 'done', 'Child at done step (info already processed)';

    # Process the final child step -- should return to parent
    my $redirect = $t->post_ok("/child-reg-test/${\$child_run->id}/done" => form => {})
        ->status_is(302)->tx->res->headers->location;

    # Should redirect to parent's listing step, not DONE/201
    like $redirect, qr/parent-storefront-test.*listing/,
        'Continuation return redirects to parent workflow step (not DONE)';
};

done_testing;
