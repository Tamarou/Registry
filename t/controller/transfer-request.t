#!/usr/bin/env perl
# ABOUTME: Controller test for parent transfer request workflow at HTTP layer.
# ABOUTME: Tests the flow: select enrollment, select target session, provide reason, review, submit.

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
use Registry::DAO::Enrollment;
use Registry::DAO::WorkflowRun;
use Mojo::Home;
use YAML::XS qw(Load);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# Import all workflows
my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml($dao, $file->slurp);
}

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

# --- Test Data Setup ---

my $location = $dao->create(Location => {
    name => 'Transfer Test Studio', slug => 'transfer-studio',
    address_info => { street => '1 Main', city => 'Orlando', state => 'FL' },
    metadata => {},
});

my $program = $dao->create(Project => {
    name => 'Transfer Test Camp', program_type_slug => 'summer-camp', metadata => {},
});

my $teacher = $dao->create(User => { username => 'transfer_teacher', user_type => 'staff' });

# Source session (currently enrolled)
my $source_session = $dao->create(Session => {
    name => 'Week 1 - Source', start_date => '2026-06-01', end_date => '2026-06-05',
    status => 'published', capacity => 16, metadata => {},
});

my $source_event = $dao->create(Event => {
    time => '2026-06-01 09:00:00', duration => 420,
    location_id => $location->id, project_id => $program->id,
    teacher_id => $teacher->id, capacity => 16, metadata => {},
});
$source_session->add_events($dao->db, $source_event->id);

# Target session (transferring to)
my $target_session = $dao->create(Session => {
    name => 'Week 2 - Target', start_date => '2026-06-08', end_date => '2026-06-12',
    status => 'published', capacity => 16, metadata => {},
});

my $target_event = $dao->create(Event => {
    time => '2026-06-08 09:00:00', duration => 420,
    location_id => $location->id, project_id => $program->id,
    teacher_id => $teacher->id, capacity => 16, metadata => {},
});
$target_session->add_events($dao->db, $target_event->id);

# Parent with enrolled child in source session
my $parent = $dao->create(User => {
    username => 'transfer_parent', name => 'Transfer Parent',
    user_type => 'parent', email => 'transfer@example.com',
});

my $child = Registry::DAO::Family->add_child($dao->db, $parent->id, {
    child_name => 'Transfer Kid', birth_date => '2018-01-01', grade => '3',
    medical_info => {}, emergency_contact => { name => 'P', phone => '555' },
});

my $enrollment = Registry::DAO::Enrollment->create($dao->db, {
    session_id       => $source_session->id,
    family_member_id => $child->id,
    parent_id        => $parent->id,
    status           => 'active',
});

my ($workflow) = $dao->find(Workflow => { slug => 'parent-transfer-request' });
ok $workflow, 'parent-transfer-request workflow exists';

# Helper: create a run pre-seeded through select-enrollment step
sub create_transfer_run {
    my $first_step = $workflow->first_step($dao->db);
    my $run = Registry::DAO::WorkflowRun->create($dao->db, {
        workflow_id => $workflow->id,
    });

    # Seed user data
    $run->update_data($dao->db, {
        user_id => $parent->id,
        user    => { id => $parent->id, name => $parent->name, role => 'parent' },
    });

    # Process select-enrollment with enrollment_id
    $run->process($dao->db, $first_step, { enrollment_id => $enrollment->id });

    return $run;
}

# ============================================================
# Test: Select target session and collect reason
# ============================================================
subtest 'select target session and provide reason' => sub {
    my $run = create_transfer_run();
    ($run) = $dao->find(WorkflowRun => { id => $run->id });

    my $step = $run->next_step($dao->db);
    is $step->slug, 'select-target-session', 'At select-target-session step';

    # Select target session
    my $redirect = $t->post_ok(workflow_process_step_url($workflow, $run, $step) => form => {
        target_session_id => $target_session->id,
    })->status_is(302)->tx->res->headers->location;

    like $redirect, qr/collect-reason$/, 'Redirected to collect-reason';

    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    is $run->data->{target_session_id}, $target_session->id, 'Target session ID stored';

    # Provide reason
    $step = $run->next_step($dao->db);
    is $step->slug, 'collect-reason', 'At collect-reason step';

    $redirect = $t->post_ok(workflow_process_step_url($workflow, $run, $step) => form => {
        reason => 'Scheduling conflict with family vacation during week 1',
    })->status_is(302)->tx->res->headers->location;

    like $redirect, qr/review-request$/, 'Redirected to review-request';

    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    like $run->data->{reason}, qr/vacation/, 'Reason stored in run data';
};

# ============================================================
# Test: Full transfer request flow to completion
# ============================================================
subtest 'full transfer request flow completes' => sub {
    my $run = create_transfer_run();

    # Select target session
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    my $step = $run->next_step($dao->db);
    $t->post_ok(workflow_process_step_url($workflow, $run, $step) => form => {
        target_session_id => $target_session->id,
    })->status_is(302);

    # Collect reason
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    $step = $run->next_step($dao->db);
    $t->post_ok(workflow_process_step_url($workflow, $run, $step) => form => {
        reason => 'Need to switch to a different week due to summer travel plans',
    })->status_is(302);

    # Review
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    $step = $run->next_step($dao->db);
    is $step->slug, 'review-request', 'At review-request step';
    $t->post_ok(workflow_process_step_url($workflow, $run, $step) => form => {
        confirm => 1,
    })->status_is(302);

    # Submit
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    $step = $run->next_step($dao->db);
    is $step->slug, 'submit-request', 'At submit-request step';
    $t->post_ok(workflow_process_step_url($workflow, $run, $step) => form => {})
      ->status_is(302);

    # Complete
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    $step = $run->next_step($dao->db);
    is $step->slug, 'complete', 'At complete step';
    $t->post_ok(workflow_process_step_url($workflow, $run, $step) => form => {})
      ->status_is(201);

    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    ok $run->completed($dao->db), 'Transfer request workflow completed';
};

# ============================================================
# Test: Full session rejected
# ============================================================
subtest 'full target session rejected' => sub {
    # Fill the target session to capacity
    for my $i (1..16) {
        my $fp = $dao->create(User => {
            username => "xfer_filler_$i", name => "Filler $i",
            user_type => 'parent', email => "xfer_filler_$i\@example.com",
        });
        my $fc = Registry::DAO::Family->add_child($dao->db, $fp->id, {
            child_name => "Filler Kid $i", birth_date => '2018-01-01', grade => '3',
            medical_info => {}, emergency_contact => { name => 'P', phone => '555' },
        });
        $dao->db->insert('enrollments', {
            session_id => $target_session->id, student_id => $fp->id,
            family_member_id => $fc->id, status => 'active',
        });
    }

    my $run = create_transfer_run();
    ($run) = $dao->find(WorkflowRun => { id => $run->id });

    my $step = $run->next_step($dao->db);
    is $step->slug, 'select-target-session', 'At select-target-session step';

    # Try to select the full session
    my $redirect = $t->post_ok(workflow_process_step_url($workflow, $run, $step) => form => {
        target_session_id => $target_session->id,
    })->status_is(302)->tx->res->headers->location;

    # Should stay on select-target-session (error about full session)
    like $redirect, qr/select-target-session$/, 'Full session stays on step';
};

done_testing;
