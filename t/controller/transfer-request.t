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
    authenticate_as
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

my $program = $dao->create(Project => { status => 'published',
    name => 'Transfer Test Camp', program_type_slug => 'summer-camp', metadata => {},
});

my $teacher = $dao->create(User => { username => 'transfer_teacher', user_type => 'staff' });

# A transfer is only offered out of a session that has not started --
# _get_transferable_enrollments filters on s.start_date > NOW() -- and only
# into one that has not started either. Both windows are derived so they stay
# ahead of the day the suite runs.
my $source_start = days_from_now(14);
my $source_end   = days_from_now(18);
my $target_start = days_from_now(21);
my $target_end   = days_from_now(25);

# Source session (currently enrolled)
my $source_session = $dao->create(Session => {
    name => 'Week 1 - Source', start_date => $source_start, end_date => $source_end,
    status => 'published', capacity => 16, metadata => {},
});

my $source_event = $dao->create(Event => {
    time => "$source_start 09:00:00", duration => 420,
    location_id => $location->id, project_id => $program->id,
    teacher_id => $teacher->id, capacity => 16, metadata => {},
});
$source_session->add_events($dao->db, $source_event->id);

# Target session (transferring to)
my $target_session = $dao->create(Session => {
    name => 'Week 2 - Target', start_date => $target_start, end_date => $target_end,
    status => 'published', capacity => 16, metadata => {},
});

my $target_event = $dao->create(Event => {
    time => "$target_start 09:00:00", duration => 420,
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

authenticate_as($t, $parent);

# A run the way a parent gets one: the dashboard's Transfer link, followed while
# signed in. The acting user is whoever the session says, so nothing here hands
# the run a user of its own -- a hand-seeded one would test a state no request
# can produce.
sub create_transfer_run {
    # A fresh session per run, so a subtest starts its own rather than resuming
    # the one the previous subtest left unfinished.
    $t->reset_session;
    $t->get_ok( workflow_url($workflow) . '?enrollment_id=' . $enrollment->id )
      ->status_is(200);

    my $run = $workflow->latest_run($dao->db);
    is $run->data->{enrollment_id}, $enrollment->id,
      'the link put the run on this enrollment';

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

    # Submit. The step reports its own failures as an error the run keeps, so
    # the request itself is read back from the table rather than inferred from
    # having arrived at the next step.
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    $step = $run->next_step($dao->db);
    is $step->slug, 'submit-request', 'At submit-request step';
    $t->post_ok(workflow_process_step_url($workflow, $run, $step) => form => {})
      ->status_is(302);

    my $request = $dao->db->select('transfer_requests', '*',
        { enrollment_id => $enrollment->id })->hash;
    ok $request, 'a transfer request was written for this enrollment';
    is $request->{requested_by}, $parent->id, 'requested by the signed-in parent';
    is $request->{target_session_id}, $target_session->id, 'for the session chosen';

    # Complete.
    #
    # This step keeps no logic of its own, so whatever the request sent is what
    # gets written back into the run -- which is where a user[id] of a client's
    # choosing would land, and the acting user a step reads off the run is the
    # family_id its ownership check matches on. So the last POST of the flow
    # carries the bracketed key an attacker would use, and the run has to come
    # out of it still acting as the parent who is signed in.
    my $other_parent = $dao->create(User => {
        username => 'transfer_other_parent', name => 'Other Parent',
        user_type => 'parent', email => 'transfer_other@example.com',
    });

    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    $step = $run->next_step($dao->db);
    is $step->slug, 'complete', 'At complete step';
    $t->post_ok(workflow_process_step_url($workflow, $run, $step) => form => {
        'user[id]' => $other_parent->id,
        user_id    => $other_parent->id,
    })->status_is(201);

    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    is $run->data->{user}{id}, $parent->id,
      'the run still acts as the signed-in parent, not the id the request sent';
    is $run->data->{user_id}, $parent->id,
      'and the same for the id the payment steps read';
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
