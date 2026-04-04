#!/usr/bin/env perl
# ABOUTME: Controller test for returning parent happy path through summer camp registration workflow.
# ABOUTME: Tests login via continue_logged_in, existing child selection, session selection, and demo payment.

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

# --- Test Data Setup: Returning Parent ---

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

my $teacher = $dao->create(User => { username => 'camp_teacher_ret', user_type => 'staff' });

my $session_week2 = $dao->create(Session => {
    name       => 'Week 2 - Jun 8-12',
    start_date => '2026-06-08',
    end_date   => '2026-06-12',
    status     => 'published',
    capacity   => 16,
    metadata   => {},
});

my $event = $dao->create(Event => {
    time        => '2026-06-08 09:00:00',
    duration    => 420,
    location_id => $location->id,
    project_id  => $program->id,
    teacher_id  => $teacher->id,
    capacity    => 16,
    metadata    => {},
});
$session_week2->add_events($dao->db, $event->id);

$dao->create(PricingPlan => {
    session_id => $session_week2->id,
    plan_name  => 'Standard',
    plan_type  => 'standard',
    amount     => 300.00,
});

# Pre-existing returning parent with a child
my $returning_parent = $dao->create(User => {
    username  => 'nancy.returning',
    name      => 'Nancy Returning',
    email     => 'nancy.returning@example.com',
    user_type => 'parent',
});

my $existing_child = Registry::DAO::Family->add_child($dao->db, $returning_parent->id, {
    child_name => 'Emma Johnson',
    birth_date => '2018-03-15',
    grade      => '3',
    medical_info => {
        allergies   => ['latex'],
        medications => [],
        notes       => 'Carries inhaler',
    },
    emergency_contact => {
        name         => 'Nancy Returning',
        phone        => '407-555-9876',
        relationship => 'Mother',
    },
});

# Count users and family members before the test to verify no new ones are created
my $user_count_before = $dao->db->select('users', 'COUNT(*)')->array->[0];
my $child_count_before = $dao->db->select('family_members', 'COUNT(*)')->array->[0];

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
};

my $run = $workflow->latest_run($dao->db);
ok $run, 'Workflow run exists';

# === Step 2: Account check - continue as logged-in user ===
subtest 'Account check - continue as logged-in returning parent' => sub {
    my $step = $run->next_step($dao->db);
    is $step->slug, 'account-check', 'Next step is account-check';

    my $step_url = workflow_process_step_url($workflow, $run, $step);
    my $next_url = $t->post_ok($step_url => form => {
        action  => 'continue_logged_in',
        user_id => $returning_parent->id,
    })->status_is(302)
      ->tx->res->headers->location;

    ok $next_url, 'Redirected after login';
    like $next_url, qr/select-children$/, 'Redirected to select-children step';

    # Verify user info stored in run data
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    is $run->data->{user_id}, $returning_parent->id, 'Returning parent user_id in run data';
    is $run->data->{user_name}, 'Nancy Returning', 'user_name in run data';
    is $run->data->{user_email}, 'nancy.returning@example.com', 'user_email in run data';
};

# === Step 3: Select existing child ===
subtest 'Select children - continue with existing child Emma' => sub {
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    my $step = $run->next_step($dao->db);
    is $step->slug, 'select-children', 'Next step is select-children';

    my $step_url = workflow_process_step_url($workflow, $run, $step);
    my $next_url = $t->post_ok($step_url => form => {
        action                          => 'continue',
        "child_${\$existing_child->id}" => 1,
    })->status_is(302)
      ->tx->res->headers->location;

    ok $next_url, 'Redirected after child selection';
    like $next_url, qr/camper-info$/, 'Redirected to camper-info step';

    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    my $selected = $run->data->{selected_child_ids};
    is scalar @$selected, 1, 'One child selected';
    is $selected->[0], $existing_child->id, 'Existing child Emma selected';
};

# === Step 4: Camper info ===
subtest 'Camper info - submit for existing child' => sub {
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    my $step = $run->next_step($dao->db);
    is $step->slug, 'camper-info', 'Next step is camper-info';

    my $step_url = workflow_process_step_url($workflow, $run, $step);
    my $next_url = $t->post_ok($step_url => form => {
        childName  => 'Emma Johnson',
        gradeLevel => '3',
    })->status_is(302)
      ->tx->res->headers->location;

    ok $next_url, 'Redirected after camper info';
    like $next_url, qr/session-selection$/, 'Redirected to session-selection step';
};

# === Step 5: Session selection - pick Week 2 ===
subtest 'Session selection - pick Week 2' => sub {
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    my $step = $run->next_step($dao->db);
    is $step->slug, 'session-selection', 'Next step is session-selection';

    my $step_url = workflow_process_step_url($workflow, $run, $step);
    my $next_url = $t->post_ok($step_url => form => {
        action                                  => 'select_sessions',
        "session_for_${\$existing_child->id}"   => $session_week2->id,
    })->status_is(302)
      ->tx->res->headers->location;

    ok $next_url, 'Redirected after session selection';
    like $next_url, qr/payment$/, 'Redirected to payment step';
};

# === Step 6: Payment (demo mode) ===
subtest 'Payment - demo mode' => sub {
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
subtest 'No new user or child created' => sub {
    my $user_count_after = $dao->db->select('users', 'COUNT(*)')->array->[0];
    my $child_count_after = $dao->db->select('family_members', 'COUNT(*)')->array->[0];

    is $user_count_after, $user_count_before, 'No new users created';
    is $child_count_after, $child_count_before, 'No new family members created';
};

subtest 'Enrollment created for existing child in Week 2' => sub {
    my $enrollment = Registry::DAO::Enrollment->find($dao->db, {
        family_member_id => $existing_child->id,
        session_id       => $session_week2->id,
    });

    ok $enrollment, 'Enrollment created in database';
    is $enrollment->status, 'active', 'Enrollment status is active';
};

subtest 'Existing child data preserved' => sub {
    my $fm = Registry::DAO::FamilyMember->find($dao->db, { id => $existing_child->id });
    ok $fm, 'FamilyMember still exists';
    is $fm->child_name, 'Emma Johnson', 'Child name preserved';
    is $fm->grade, '3', 'Grade preserved';
    is $fm->family_id, $returning_parent->id, 'Still linked to returning parent';

    # Verify medical info preserved
    my $medical = $fm->medical_info;
    ok $medical, 'Medical info exists';
    is_deeply $medical->{allergies}, ['latex'], 'Allergies preserved';
    is $medical->{notes}, 'Carries inhaler', 'Medical notes preserved';
};

done_testing;
