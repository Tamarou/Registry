#!/usr/bin/env perl
# ABOUTME: Controller test for new parent happy path through summer camp registration workflow.
# ABOUTME: Tests account creation, child selection, session selection, and demo-mode payment at HTTP layer.

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

# Ensure demo payment mode (no Stripe key)
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

# Create test entities needed for the registration flow
my $location = $dao->create(Location => {
    name         => 'Pottery Studio',
    address_info => { street => '930 Hoffner Ave', city => 'Orlando', state => 'FL' },
    metadata     => {},
});

my $program = $dao->create(Project => {
    name              => 'Summer Art Camp 2026',
    notes             => 'FULL Day Camp | M-F | 9am-4pm | Grades K to 5',
    program_type_slug => 'summer-camp',
    metadata          => {},
});

my $teacher = $dao->create(User => { username => 'camp_teacher_test', user_type => 'staff' });

my $session = $dao->create(Session => {
    name       => 'Week 1 - Jun 1-5',
    start_date => '2026-06-01',
    end_date   => '2026-06-05',
    status     => 'published',
    capacity   => 16,
    metadata   => {},
});

# Create events for the session
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

# Create pricing plan for the session
$dao->create(PricingPlan => {
    session_id => $session->id,
    plan_name  => 'Standard',
    plan_type  => 'standard',
    amount     => 300.00,
});

# --- Find the workflow ---
my ($workflow) = $dao->find(Workflow => { slug => 'summer-camp-registration' });
ok $workflow, 'summer-camp-registration workflow exists';

# === Step 1: Start the workflow ===
subtest 'Start registration workflow' => sub {
    my $start_url = workflow_url($workflow);
    my $next_url = $t->post_ok($start_url => form => {})
        ->status_is(302)
        ->tx->res->headers->location;

    ok $next_url, 'Redirected after starting workflow';
    like $next_url, qr/account-check$/, 'Redirected to account-check step';

    # Verify a workflow run was created
    is $workflow->runs($dao->db), 1, 'One workflow run created';
};

# Get the run for subsequent steps
my $run = $workflow->latest_run($dao->db);
ok $run, 'Workflow run exists';

# === Step 2: Account check - create new account ===
subtest 'Account check - create new account' => sub {
    my $step = $run->next_step($dao->db);
    is $step->slug, 'account-check', 'Next step is account-check';

    my $step_url = workflow_process_step_url($workflow, $run, $step);
    my $next_url = $t->post_ok($step_url => form => {
        action   => 'create_account',
        username => 'maria.martinez',
        email    => 'maria.martinez@example.com',
        name     => 'Maria Martinez',
    })->status_is(302)
      ->tx->res->headers->location;

    ok $next_url, 'Redirected after account creation';
    like $next_url, qr/select-children$/, 'Redirected to select-children step';

    # Verify user was created in DB
    my $user = Registry::DAO::User->find($dao->db, { username => 'maria.martinez' });
    ok $user, 'User created in database';
    is $user->email, 'maria.martinez@example.com', 'User email correct';
    is $user->user_type, 'parent', 'User type is parent';
    ok !$user->passhash, 'No password hash (passwordless)';

    # Verify user_id stored in run data
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    is $run->data->{user_id}, $user->id, 'user_id stored in workflow run data';
};

# === Step 3: Select children ===
# Pre-create child via DAO because the "stay" semantics for add_child
# don't work at the HTTP layer yet.  WorkflowRun::process now handles
# stay correctly (#153), but the controller's stay rendering path needs
# work to properly re-render SelectChildren with the updated children
# list after an add_child action.

my $user = Registry::DAO::User->find($dao->db, { username => 'maria.martinez' });
my $child = Registry::DAO::Family->add_child($dao->db, $user->id, {
    child_name => 'Liam Martinez',
    birth_date => '2017-09-01',
    grade      => '3',
    medical_info => {
        allergies   => ['peanuts'],
        medications => [],
        notes       => '',
    },
    emergency_contact => {
        name         => 'Sofia Martinez',
        phone        => '407-555-0123',
        relationship => 'Mother',
    },
});

subtest 'Select children - continue with existing child' => sub {
    my $step = $run->next_step($dao->db);
    is $step->slug, 'select-children', 'Next step is select-children';

    my $step_url = workflow_process_step_url($workflow, $run, $step);
    my $next_url = $t->post_ok($step_url => form => {
        action             => 'continue',
        "child_${\$child->id}" => 1,
    })->status_is(302)
      ->tx->res->headers->location;

    ok $next_url, 'Redirected after child selection';
    like $next_url, qr/camper-info$/, 'Redirected to camper-info step';

    # Verify selected_child_ids stored in run data
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    my $selected = $run->data->{selected_child_ids};
    ok $selected, 'selected_child_ids stored in run data';
    is scalar @$selected, 1, 'One child selected';
    is $selected->[0], $child->id, 'Correct child ID selected';
};

# === Step 4: Camper info ===
subtest 'Camper info - submit form data' => sub {
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    my $step = $run->next_step($dao->db);
    is $step->slug, 'camper-info', 'Next step is camper-info';

    my $step_url = workflow_process_step_url($workflow, $run, $step);
    my $next_url = $t->post_ok($step_url => form => {
        childName  => 'Liam Martinez',
        gradeLevel => '3',
    })->status_is(302)
      ->tx->res->headers->location;

    ok $next_url, 'Redirected after camper info';
    like $next_url, qr/session-selection$/, 'Redirected to session-selection step';
};

# === Step 5: Session selection ===
subtest 'Session selection - pick Week 1' => sub {
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    my $step = $run->next_step($dao->db);
    is $step->slug, 'session-selection', 'Next step is session-selection';

    my $step_url = workflow_process_step_url($workflow, $run, $step);
    my $next_url = $t->post_ok($step_url => form => {
        action                     => 'select_sessions',
        "session_for_${\$child->id}" => $session->id,
    })->status_is(302)
      ->tx->res->headers->location;

    ok $next_url, 'Redirected after session selection';
    like $next_url, qr/payment$/, 'Redirected to payment step';

    # Verify enrollment_items stored in run data
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    my $items = $run->data->{enrollment_items};
    ok $items, 'enrollment_items stored in run data';
    is scalar @$items, 1, 'One enrollment item';
    is $items->[0]{child_id}, $child->id, 'Enrollment item has correct child_id';
    is $items->[0]{session_id}, $session->id, 'Enrollment item has correct session_id';
};

# === Step 6: Payment (demo mode) ===
subtest 'Payment - demo mode with agreeTerms' => sub {
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    my $step = $run->next_step($dao->db);
    is $step->slug, 'payment', 'Next step is payment';

    my $step_url = workflow_process_step_url($workflow, $run, $step);
    my $next_url = $t->post_ok($step_url => form => {
        agreeTerms => 1,
    })->status_is(302)
      ->tx->res->headers->location;

    ok $next_url, 'Redirected after payment';
    like $next_url, qr/complete$/, 'Redirected to complete step';
};

# === Step 7: Complete ===
subtest 'Complete step finalizes workflow' => sub {
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    my $step = $run->next_step($dao->db);
    is $step->slug, 'complete', 'Next step is complete';

    my $step_url = workflow_process_step_url($workflow, $run, $step);
    $t->post_ok($step_url => form => {})
      ->status_is(201);

    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    ok $run->completed($dao->db), 'Workflow run is completed';
};

# === Final assertions ===
subtest 'Enrollment and family member data correct' => sub {
    # Verify enrollment was created in database
    my $enrollment = Registry::DAO::Enrollment->find($dao->db, {
        family_member_id => $child->id,
        session_id       => $session->id,
    });

    ok $enrollment, 'Enrollment created in database';
    is $enrollment->status, 'active', 'Enrollment status is active';

    # Verify the family member data
    my $fm = Registry::DAO::FamilyMember->find($dao->db, { id => $child->id });
    ok $fm, 'FamilyMember exists';
    is $fm->child_name, 'Liam Martinez', 'Child name correct';
    is $fm->grade, '3', 'Grade correct';
    is $fm->family_id, $user->id, 'Linked to correct parent';
};

done_testing;
