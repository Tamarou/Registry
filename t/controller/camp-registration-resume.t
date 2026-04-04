#!/usr/bin/env perl
# ABOUTME: Controller test for abandoned workflow resume.
# ABOUTME: Verifies that navigating back to a workflow run URL preserves child data and allows continuation.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw(
    workflow_url
    workflow_run_step_url
    workflow_process_step_url
);

use Registry::DAO qw(Workflow);
use Registry::DAO::User;
use Registry::DAO::Family;
use Registry::DAO::FamilyMember;
use Registry::DAO::Enrollment;
use Mojo::Home;
use YAML::XS qw(Load);

# Ensure demo payment mode
delete $ENV{STRIPE_SECRET_KEY};

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# Import all non-draft workflows from YAML
my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml($dao, $file->slurp);
}

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

# --- Test Data Setup ---

my $location = $dao->create(Location => {
    name         => 'Resume Test Studio',
    address_info => { street => '100 Main', city => 'Orlando', state => 'FL' },
    metadata     => {},
});

my $program = $dao->create(Project => {
    name              => 'Summer Camp Resume Test',
    program_type_slug => 'summer-camp',
    metadata          => {},
});

my $teacher = $dao->create(User => { username => 'camp_teacher_resume', user_type => 'staff' });

my $session = $dao->create(Session => {
    name       => 'Week 1 - Jun 1-5',
    start_date => '2026-06-01',
    end_date   => '2026-06-05',
    status     => 'published',
    capacity   => 16,
    metadata   => {},
});

my $event = $dao->create(Event => {
    time        => '2026-06-01 09:00:00',
    duration    => 420,
    location_id => $location->id,
    project_id  => $program->id,
    teacher_id  => $teacher->id,
    capacity    => 16,
    metadata    => {},
});
$session->add_events($dao->db, $event->id);

$dao->create(PricingPlan => {
    session_id => $session->id,
    plan_name  => 'Standard',
    plan_type  => 'standard',
    amount     => 300.00,
});

my ($workflow) = $dao->find(Workflow => { slug => 'summer-camp-registration' });
ok $workflow, 'summer-camp-registration workflow exists';

# === Phase 1: Start workflow, advance to select-children, add child ===

subtest 'Start workflow and advance to select-children' => sub {
    # Start the workflow
    $t->post_ok(workflow_url($workflow) => form => {})
      ->status_is(302);

    my $run = $workflow->latest_run($dao->db);
    ok $run, 'Workflow run created';

    # Account check - create account
    my $step = $run->next_step($dao->db);
    $t->post_ok(workflow_process_step_url($workflow, $run, $step) => form => {
        action   => 'create_account',
        username => 'resume.parent',
        email    => 'resume.parent@example.com',
        name     => 'Resume Parent',
    })->status_is(302);

    # Pre-create child (workaround for stay semantics)
    my $user = Registry::DAO::User->find($dao->db, { username => 'resume.parent' });
    ok $user, 'Parent user created';

    Registry::DAO::Family->add_child($dao->db, $user->id, {
        child_name => 'Olivia Resume',
        birth_date => '2018-07-20',
        grade      => '2',
        medical_info => {
            allergies   => ['pollen'],
            medications => [],
            notes       => 'Seasonal allergies',
        },
        emergency_contact => {
            name         => 'Resume Parent',
            phone        => '407-555-7777',
            relationship => 'Mother',
        },
    });

    # Verify run data has user_id
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    ok $run->data->{user_id}, 'user_id stored in run data';
};

# Record the run ID and step URL for resumption
my $run = $workflow->latest_run($dao->db);
my $run_id = $run->id;
my $step = $run->next_step($dao->db);
is $step->slug, 'select-children', 'Current step is select-children';

my $resume_url = workflow_run_step_url($workflow, $run, $step);

# === Phase 2: Verify run data persists in DB ===

subtest 'Workflow run data preserved in database' => sub {
    my ($fresh_run) = $dao->find(WorkflowRun => { id => $run_id });
    ok $fresh_run, 'Workflow run found by ID';

    my $data = $fresh_run->data;
    ok $data->{user_id}, 'user_id preserved in run data';

    # Verify the user_id points to a valid user
    my $user = Registry::DAO::User->find($dao->db, { id => $data->{user_id} });
    ok $user, 'user_id references a valid user';
    is $user->name, 'Resume Parent', 'User name accessible via user_id lookup';
};

# === Phase 3: "Close browser" - create fresh Test::Mojo instance ===

subtest 'Resume workflow in new session - GET step renders with child data' => sub {
    # Fresh Test::Mojo simulates a new browser session (no cookies)
    my $t2 = Test::Registry::Mojo->new('Registry');
    $t2->app->helper(dao => sub { $dao });

    # GET the workflow step URL directly (as if pasting URL in new browser)
    $t2->get_ok($resume_url)
       ->status_is(200, 'Step page renders OK on resume');

    # Verify the page contains the child name
    $t2->content_like(qr/Olivia Resume/, 'Child name visible on resumed page');
};

# === Phase 4: Continue the workflow from the resumed step ===

subtest 'Can continue workflow from resumed step' => sub {
    my $t2 = Test::Registry::Mojo->new('Registry');
    $t2->app->helper(dao => sub { $dao });

    # Find the child to select
    my $user = Registry::DAO::User->find($dao->db, { username => 'resume.parent' });
    my $children = Registry::DAO::Family->list_children($dao->db, $user->id);
    ok scalar @$children >= 1, 'Child exists for user';
    my $child = $children->[0];

    # POST to select-children with the child selected
    my $next_url = $t2->post_ok(workflow_process_step_url($workflow, $run, $step) => form => {
        action                      => 'continue',
        "child_${\$child->id}"      => 1,
    })->status_is(302)
      ->tx->res->headers->location;

    like $next_url, qr/camper-info$/, 'Redirected to camper-info (workflow continues)';

    # Verify selected_child_ids in run data
    my ($resumed_run) = $dao->find(WorkflowRun => { id => $run_id });
    my $selected = $resumed_run->data->{selected_child_ids};
    ok $selected, 'selected_child_ids stored after resume';
    is $selected->[0], $child->id, 'Correct child selected after resume';
};

done_testing;
