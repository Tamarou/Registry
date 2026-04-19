#!/usr/bin/env perl
# ABOUTME: Controller tests for registration workflow unhappy paths.
# ABOUTME: Tests duplicate email, full session, and age mismatch error handling.

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

my ($workflow) = $dao->find(Workflow => { slug => 'summer-camp-registration' });
ok $workflow, 'summer-camp-registration workflow exists';

# --- Shared test data ---

my $location = $dao->create(Location => {
    name         => 'Test Studio',
    address_info => { street => '123 Main', city => 'Orlando', state => 'FL' },
    metadata     => {},
});

my $program = $dao->create(Project => { status => 'published',
    name              => 'Summer Camp Errors Test',
    program_type_slug => 'summer-camp',
    metadata          => { age_range => { min => 5, max => 11 } },
});

my $teacher = $dao->create(User => { username => 'camp_teacher_err', user_type => 'staff' });

# Session with plenty of capacity
my $open_session = $dao->create(Session => {
    name       => 'Open Session',
    start_date => '2026-06-01',
    end_date   => '2026-06-05',
    status     => 'published',
    capacity   => 16,
    metadata   => {},
});

my $open_event = $dao->create(Event => {
    time        => '2026-06-01 09:00:00',
    duration    => 420,
    location_id => $location->id,
    project_id  => $program->id,
    teacher_id  => $teacher->id,
    capacity    => 16,
    metadata    => {},
});
$open_session->add_events($dao->db, $open_event->id);

$dao->create(PricingPlan => {
    session_id => $open_session->id,
    plan_name  => 'Standard',
    plan_type  => 'standard',
    amount     => 300.00,
});

# Full session (capacity 2, with 2 enrollments)
my $full_session = $dao->create(Session => {
    name       => 'Full Session',
    start_date => '2026-06-15',
    end_date   => '2026-06-19',
    status     => 'published',
    capacity   => 2,
    metadata   => {},
});

my $full_event = $dao->create(Event => {
    time        => '2026-06-15 09:00:00',
    duration    => 420,
    location_id => $location->id,
    project_id  => $program->id,
    teacher_id  => $teacher->id,
    capacity    => 2,
    metadata    => {},
});
$full_session->add_events($dao->db, $full_event->id);

$dao->create(PricingPlan => {
    session_id => $full_session->id,
    plan_name  => 'Standard',
    plan_type  => 'standard',
    amount     => 300.00,
});

# Fill the full session with 2 enrollments
my $filler_parent1 = $dao->create(User => {
    username => 'filler_parent1', name => 'Filler Parent 1',
    user_type => 'parent', email => 'filler1@example.com',
});
my $filler_child1 = Registry::DAO::Family->add_child($dao->db, $filler_parent1->id, {
    child_name => 'Filler Child 1', birth_date => '2017-01-01', grade => '3',
    medical_info => {}, emergency_contact => { name => 'Parent', phone => '555-0001' },
});
$dao->db->insert('enrollments', {
    session_id => $full_session->id, student_id => $filler_parent1->id,
    family_member_id => $filler_child1->id, status => 'active',
});

my $filler_parent2 = $dao->create(User => {
    username => 'filler_parent2', name => 'Filler Parent 2',
    user_type => 'parent', email => 'filler2@example.com',
});
my $filler_child2 = Registry::DAO::Family->add_child($dao->db, $filler_parent2->id, {
    child_name => 'Filler Child 2', birth_date => '2017-06-01', grade => '3',
    medical_info => {}, emergency_contact => { name => 'Parent', phone => '555-0002' },
});
$dao->db->insert('enrollments', {
    session_id => $full_session->id, student_id => $filler_parent2->id,
    family_member_id => $filler_child2->id, status => 'active',
});

# Pre-existing user for duplicate email test
my $existing_user = $dao->create(User => {
    username  => 'existing.parent',
    name      => 'Existing Parent',
    email     => 'existing@example.com',
    user_type => 'parent',
});

# ============================================================
# 1.3 Duplicate Email
# ============================================================
subtest 'duplicate email - shows error, not 500' => sub {
    # Start a fresh workflow run
    my $start_url = workflow_url($workflow);
    my $redirect = $t->post_ok($start_url => form => {})
        ->status_is(302)->tx->res->headers->location;

    my $run = $workflow->latest_run($dao->db);
    my $step = $run->next_step($dao->db);
    is $step->slug, 'account-check', 'At account-check step';

    my $step_url = workflow_process_step_url($workflow, $run, $step);

    # Count users before
    my $user_count_before = $dao->db->select('users', 'COUNT(*)')->array->[0];

    # POST create_account with email belonging to existing user
    my $response = $t->post_ok($step_url => form => {
        action   => 'create_account',
        username => 'existing.parent',
        email    => 'existing@example.com',
        name     => 'Duplicate Attempt',
    });

    # Should redirect back to same step with errors (302), NOT 500
    $response->status_is(302, 'Duplicate email returns 302, not 500');

    my $redirect_url = $response->tx->res->headers->location;
    like $redirect_url, qr/account-check/, 'Redirected back to account-check (not next step)';

    # No duplicate user created
    my $user_count_after = $dao->db->select('users', 'COUNT(*)')->array->[0];
    is $user_count_after, $user_count_before, 'No duplicate user created in DB';
};

# ============================================================
# Helper: advance a run through account-check and select-children
# to reach session-selection step
# ============================================================
sub advance_to_session_selection ($username, $email, $child_name, $birth_date, $grade) {
    my $start_url = workflow_url($workflow);
    $t->post_ok($start_url => form => {})->status_is(302);

    my $run = $workflow->latest_run($dao->db);

    # Account check - create account
    my $step = $run->next_step($dao->db);
    my $step_url = workflow_process_step_url($workflow, $run, $step);
    $t->post_ok($step_url => form => {
        action => 'create_account', username => $username,
        email => $email, name => 'Test Parent',
    })->status_is(302);

    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    my $user = Registry::DAO::User->find($dao->db, { username => $username });

    # Set program_id in run data (normally set by storefront/landing page)
    $run->update_data($dao->db, { program_id => $program->id });

    # Pre-create child
    my $child = Registry::DAO::Family->add_child($dao->db, $user->id, {
        child_name => $child_name, birth_date => $birth_date, grade => $grade,
        medical_info => {}, emergency_contact => { name => 'Parent', phone => '555-0000' },
    });

    # Select children
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    $step = $run->next_step($dao->db);
    $step_url = workflow_process_step_url($workflow, $run, $step);
    $t->post_ok($step_url => form => {
        action => 'continue', "child_${\$child->id}" => 1,
    })->status_is(302);

    # Camper info
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    $step = $run->next_step($dao->db);
    $step_url = workflow_process_step_url($workflow, $run, $step);
    $t->post_ok($step_url => form => {
        childName => $child_name, gradeLevel => $grade,
    })->status_is(302);

    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    return ($run, $child);
}

# ============================================================
# 1.4 Full Session
# ============================================================
subtest 'full session - selecting full session returns error' => sub {
    my ($run, $child) = advance_to_session_selection(
        'fullsess_parent', 'fullsess@example.com',
        'Full Session Kid', '2017-05-01', '3',
    );

    my $step = $run->next_step($dao->db);
    is $step->slug, 'session-selection', 'At session-selection step';

    # Verify the full session is actually full
    my $enrolled = $dao->db->select('enrollments', 'COUNT(*)', {
        session_id => $full_session->id,
        status     => 'active',
    })->array->[0];
    is $enrolled, 2, 'Full session has 2 active enrollments (at capacity)';

    my $step_url = workflow_process_step_url($workflow, $run, $step);

    # Try to select the full session
    my $response = $t->post_ok($step_url => form => {
        action                        => 'select_sessions',
        "session_for_${\$child->id}"  => $full_session->id,
    });

    # Should redirect back to session-selection with an error, not proceed
    $response->status_is(302, 'Full session selection returns 302');

    my $redirect_url = $response->tx->res->headers->location;
    like $redirect_url, qr/session-selection/, 'Redirected back to session-selection (not payment)';

    # Verify no enrollment was created for the full session
    my $enrollment = $dao->db->select('enrollments', '*', {
        family_member_id => $child->id,
        session_id       => $full_session->id,
    })->hash;
    ok !$enrollment, 'No enrollment created for full session';
};

# ============================================================
# 1.5 Age Mismatch
# ============================================================
subtest 'age mismatch - underage child rejected at session selection' => sub {
    # Child born 2023 = age ~3, below K range (5-11)
    my ($run, $child) = advance_to_session_selection(
        'young_parent', 'young@example.com',
        'Tiny Tot', '2023-01-15', 'Pre-K',
    );

    my $step = $run->next_step($dao->db);
    is $step->slug, 'session-selection', 'At session-selection step';

    my $step_url = workflow_process_step_url($workflow, $run, $step);

    # Try to select a session for the underage child
    my $response = $t->post_ok($step_url => form => {
        action                        => 'select_sessions',
        "session_for_${\$child->id}"  => $open_session->id,
    });

    # Should redirect back to session-selection with age error
    $response->status_is(302, 'Age mismatch returns 302');

    my $redirect_url = $response->tx->res->headers->location;
    like $redirect_url, qr/session-selection/, 'Redirected back to session-selection (not payment)';

    # Verify no enrollment created
    my $enrollment = $dao->db->select('enrollments', '*', {
        family_member_id => $child->id,
        session_id       => $open_session->id,
    })->hash;
    ok !$enrollment, 'No enrollment created for underage child';
};

done_testing;
