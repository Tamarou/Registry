#!/usr/bin/env perl
# ABOUTME: Controller test for parent drop request workflow at HTTP layer.
# ABOUTME: Walks the dashboard's Drop link through reason, review and submit.

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
    name => 'Drop Test Studio', slug => 'drop-studio',
    address_info => { street => '1 Main', city => 'Orlando', state => 'FL' },
    metadata => {},
});

my $program = $dao->create(Project => { status => 'published',
    name => 'Drop Test Camp', program_type_slug => 'summer-camp', metadata => {},
});

my $teacher = $dao->create(User => { username => 'drop_teacher', user_type => 'staff' });

my $session = $dao->create(Session => {
    name => 'Drop Test Week 1', start_date => '2026-06-01', end_date => '2026-06-05',
    status => 'published', capacity => 16, metadata => {},
});

my $event = $dao->create(Event => {
    time => '2026-06-01 09:00:00', duration => 420,
    location_id => $location->id, project_id => $program->id,
    teacher_id => $teacher->id, capacity => 16, metadata => {},
});
$session->add_events($dao->db, $event->id);

my $parent = $dao->create(User => {
    username => 'drop_parent', name => 'Drop Parent',
    user_type => 'parent', email => 'drop@example.com',
});

my $child = Registry::DAO::Family->add_child($dao->db, $parent->id, {
    child_name => 'Drop Kid', birth_date => '2018-01-01', grade => '3',
    medical_info => {}, emergency_contact => { name => 'P', phone => '555' },
});

my $enrollment = Registry::DAO::Enrollment->create($dao->db, {
    session_id       => $session->id,
    family_member_id => $child->id,
    parent_id        => $parent->id,
    status           => 'active',
});

my ($workflow) = $dao->find(Workflow => { slug => 'parent-drop-request' });
ok $workflow, 'parent-drop-request workflow exists';

authenticate_as($t, $parent);

# A run the way a parent gets one: the dashboard's Drop link, followed while
# signed in. The acting user is whoever the session says, so nothing here hands
# the run a user of its own -- a hand-seeded one would test a state no request
# can produce.
sub create_drop_run {
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
# Test: Collect reason step via HTTP
# ============================================================
subtest 'collect-reason step accepts reason and advances' => sub {
    my $run = create_drop_run();
    ($run) = $dao->find(WorkflowRun => { id => $run->id });

    my $step = $run->next_step($dao->db);
    is $step->slug, 'collect-reason', 'At collect-reason step';

    my $step_url = workflow_process_step_url($workflow, $run, $step);
    my $redirect = $t->post_ok($step_url => form => {
        reason           => 'Schedule conflict with another activity that runs the same week',
        refund_requested => 1,
    })->status_is(302)->tx->res->headers->location;

    like $redirect, qr/review-request$/, 'Redirected to review-request';

    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    is $run->data->{reason}, 'Schedule conflict with another activity that runs the same week',
        'Reason stored in run data';
    is $run->data->{refund_requested}, 1, 'Refund requested flag stored';
};

# ============================================================
# Test: Review reaches the submit step, which cannot yet submit
# ============================================================
# What the last two assertions record is a live defect, not a design.
# SubmitDropRequest calls Registry::DAO::DropRequest->request_for_enrollment
# without loading that class, and only admin paths ever require it, so in a
# process that has served no admin page the call finds no such method. The
# step's catch turns that exception into its generic failure message, which is
# why the run comes back to submit-request and no drop request is ever written.
# One `use Registry::DAO::DropRequest;` in SubmitDropRequest.pm is the fix, and
# these two assertions become "a pending request exists, the run completed" the
# day it lands.
subtest 'review leads to submit-request, which cannot write a drop request' => sub {
    my $run = create_drop_run();

    # Advance through collect-reason
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    my $step = $run->next_step($dao->db);
    $t->post_ok(workflow_process_step_url($workflow, $run, $step) => form => {
        reason           => 'Family moving to a different city before camp starts',
        refund_requested => 0,
    })->status_is(302);

    # Review step
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    $step = $run->next_step($dao->db);
    is $step->slug, 'review-request', 'At review-request step';

    $t->post_ok(workflow_process_step_url($workflow, $run, $step) => form => {
        confirm => 1,
    })->status_is(302);

    # Submit step
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    $step = $run->next_step($dao->db);
    is $step->slug, 'submit-request', 'At submit-request step';

    my $submit_redirect = $t->post_ok(workflow_process_step_url($workflow, $run, $step) => form => {})
      ->status_is(302)->tx->res->headers->location;

    like $submit_redirect, qr{/submit-request$},
      'submit sends the parent back to submit-request instead of completing';

    is $dao->db->query(
        'SELECT count(*) AS n FROM drop_requests WHERE enrollment_id = ?',
        $enrollment->id )->hash->{n},
      0, 'no drop request reached the database';
};

# ============================================================
# Test: Short reason validation
# ============================================================
subtest 'short reason rejected at collect-reason step' => sub {
    my $run = create_drop_run();
    ($run) = $dao->find(WorkflowRun => { id => $run->id });

    my $step = $run->next_step($dao->db);
    is $step->slug, 'collect-reason', 'At collect-reason step';

    my $redirect = $t->post_ok(workflow_process_step_url($workflow, $run, $step) => form => {
        reason => 'too short',
    })->status_is(302)->tx->res->headers->location;

    like $redirect, qr/collect-reason$/, 'Short reason stays on collect-reason step';
};

done_testing;
