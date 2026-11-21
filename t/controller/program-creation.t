#!/usr/bin/env perl
# ABOUTME: Controller tests for the program-creation workflow.
# ABOUTME: Verifies the full flow: type selection -> curriculum -> requirements -> review -> create.

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
use Registry::DAO::ProgramType;
use Registry::DAO::Project;
use Mojo::Home;
use Mojo::JSON qw(encode_json decode_json);
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

# Program types are seeded by the program-types migration.
# Verify they exist rather than creating duplicates.
my $summer_camp_type = Registry::DAO::ProgramType->find($dao->db, { slug => 'summer-camp' });
my $afterschool_type = Registry::DAO::ProgramType->find($dao->db, { slug => 'afterschool' });

# ============================================================
# Verify the workflow was imported
# ============================================================

subtest 'program-creation workflow exists and has correct steps' => sub {
    my ($workflow) = $dao->find(Workflow => { slug => 'program-creation' });
    ok $workflow, 'program-creation workflow exists';

    my $first = $workflow->first_step($dao->db);
    ok $first, 'has a first step';
    is $first->slug, 'program-type-selection', 'first step is program-type-selection';

    # Walk the chain
    my $second = $first->next_step($dao->db);
    ok $second, 'has second step';
    is $second->slug, 'curriculum-details', 'second step is curriculum-details';

    my $third = $second->next_step($dao->db);
    ok $third, 'has third step';
    is $third->slug, 'requirements-and-patterns', 'third step is requirements-and-patterns';

    my $fourth = $third->next_step($dao->db);
    ok $fourth, 'has fourth step';
    is $fourth->slug, 'review-and-create', 'fourth step is review-and-create';

    my $fifth = $fourth->next_step($dao->db);
    ok $fifth, 'has fifth step';
    is $fifth->slug, 'complete', 'fifth step is complete';
};

# ============================================================
# Full happy path through the workflow via HTTP
# ============================================================

subtest 'happy path: create a program through all steps' => sub {
    my ($workflow) = $dao->find(Workflow => { slug => 'program-creation' });

    # Step 1: GET the workflow -- auto-creates run, renders type selection
    $t->get_ok('/program-creation')
      ->status_is(200)
      ->content_like(qr/Summer Camp/, 'shows program types');

    my $run = $workflow->latest_run($dao->db);
    ok $run, 'run was auto-created by GET';

    # Step 1: POST program type selection
    my $step1 = $run->next_step($dao->db);
    is $step1->slug, 'program-type-selection', 'at type selection step';

    $t->post_ok(
        workflow_process_step_url($workflow, $run, $step1) =>
        form => { program_type_slug => 'summer-camp' }
    )->status_is(302);

    # Should redirect to curriculum-details
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    my $step2 = $run->next_step($dao->db);
    is $step2->slug, 'curriculum-details', 'advanced to curriculum-details';

    # Step 2: POST curriculum details
    $t->post_ok(
        workflow_process_step_url($workflow, $run, $step2) =>
        form => {
            name               => 'Pottery Wheel Basics',
            description        => 'Learn to throw on the wheel',
            learning_objectives => 'Centering, pulling, trimming',
            materials_needed    => 'Clay, tools, glaze',
        }
    )->status_is(302);

    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    my $step3 = $run->next_step($dao->db);
    is $step3->slug, 'requirements-and-patterns', 'advanced to requirements-and-patterns';

    # Verify curriculum was persisted in run data
    ok $run->data->{curriculum}, 'curriculum data persisted';
    is $run->data->{curriculum}{name}, 'Pottery Wheel Basics', 'program name stored';

    # Step 3: POST requirements and patterns
    $t->post_ok(
        workflow_process_step_url($workflow, $run, $step3) =>
        form => {
            min_age                  => 5,
            max_age                  => 12,
            min_grade                => 'K',
            max_grade                => '6',
            staff_ratio              => '1:8',
            pattern_type             => 'weekly',
            duration_weeks           => 8,
            sessions_per_week        => 5,
            session_duration_minutes => 360,
            default_start_time       => '09:00',
        }
    )->status_is(302);

    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    my $step4 = $run->next_step($dao->db);
    is $step4->slug, 'review-and-create', 'advanced to review-and-create';

    # Verify requirements persisted
    ok $run->data->{requirements}, 'requirements data persisted';
    is $run->data->{requirements}{min_age}, 5, 'min_age stored';
    is $run->data->{requirements}{staff_ratio}, '1:8', 'staff_ratio stored';

    # Step 4: POST confirm to create the program
    $t->post_ok(
        workflow_process_step_url($workflow, $run, $step4) =>
        form => { confirm => 1 }
    )->status_is(302);

    ($run) = $dao->find(WorkflowRun => { id => $run->id });

    # Verify a Project was created
    ok $run->data->{created_project_id}, 'project ID stored in run data';

    # Step 5: Follow redirect to complete step and process it
    my $step5 = $run->next_step($dao->db);
    is $step5->slug, 'complete', 'next step is complete';
    $t->post_ok(
        workflow_process_step_url($workflow, $run, $step5) =>
        form => {}
    )->status_is(201);

    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    my $project = Registry::DAO::Project->find($dao->db, { id => $run->data->{created_project_id} });
    ok $project, 'project exists in database';
    is $project->name, 'Pottery Wheel Basics', 'project has correct name';
    is $project->program_type_slug, 'summer-camp', 'project linked to correct program type';

    # Verify metadata contains curriculum and requirements
    my $meta = $project->metadata;
    ok $meta->{curriculum}, 'metadata has curriculum';
    ok $meta->{requirements}, 'metadata has requirements';
    ok $meta->{schedule_pattern}, 'metadata has schedule_pattern';

    # Workflow should be complete (or at complete step)
    ok $run->completed($dao->db), 'workflow is completed';
};

# ============================================================
# Validation: missing required fields
# ============================================================

subtest 'validation: curriculum-details requires name and description' => sub {
    my ($workflow) = $dao->find(Workflow => { slug => 'program-creation' });

    # Reset session so _find_or_create_run creates a fresh run
    $t->reset_session;

    # Count runs before GET to identify the new one
    my $runs_before = scalar $workflow->runs($dao->db);
    $t->get_ok('/program-creation')->status_is(200);
    my @runs_after = $workflow->runs($dao->db);
    is scalar @runs_after, $runs_before + 1, 'new run created';
    # Runs ordered by created_at DESC, so first is newest
    my $run = $runs_after[0];

    # Advance past type selection
    my $step1 = $run->next_step($dao->db);
    $t->post_ok(
        workflow_process_step_url($workflow, $run, $step1) =>
        form => { program_type_slug => 'afterschool' }
    )->status_is(302);

    # Verify redirect target confirms advancement
    my $redirect = $t->tx->res->headers->location;
    like $redirect, qr/curriculum-details/, 'redirected to curriculum-details';

    # Follow redirect to get the curriculum-details page
    $t->get_ok($redirect)->status_is(200);

    # POST with empty name -- should not advance
    # Build the POST URL from the redirect URL pattern
    my $curriculum_url = $redirect;
    $t->post_ok($curriculum_url => form => { name => '', description => '' });

    # The redirect location should still be curriculum-details (validation error redirect)
    my $redirect2 = $t->tx->res->headers->location || '';
    like $redirect2, qr/curriculum-details/, 'still at curriculum-details after validation failure';
};

# ============================================================
# Validation: age range
# ============================================================

subtest 'validation: min_age > max_age is rejected' => sub {
    my ($workflow) = $dao->find(Workflow => { slug => 'program-creation' });

    $t->reset_session;
    $t->get_ok('/program-creation')->status_is(200);
    my $run = $workflow->latest_run($dao->db);

    # Advance through type selection and curriculum
    my $step1 = $run->next_step($dao->db);
    $t->post_ok(
        workflow_process_step_url($workflow, $run, $step1) =>
        form => { program_type_slug => 'summer-camp' }
    )->status_is(302);

    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    my $step2 = $run->next_step($dao->db);
    $t->post_ok(
        workflow_process_step_url($workflow, $run, $step2) =>
        form => { name => 'Test Program', description => 'A test' }
    )->status_is(302);

    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    my $step3 = $run->next_step($dao->db);
    is $step3->slug, 'requirements-and-patterns', 'at requirements step';

    # POST with min > max age
    $t->post_ok(
        workflow_process_step_url($workflow, $run, $step3) =>
        form => { min_age => 15, max_age => 5 }
    );

    # Should not advance
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    my $next = $run->next_step($dao->db);
    is $next->slug, 'requirements-and-patterns', 'still at requirements after invalid age range';
};

done_testing;
