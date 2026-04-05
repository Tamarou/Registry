#!/usr/bin/env perl
# ABOUTME: Controller test for admin drop approval workflow at HTTP layer.
# ABOUTME: Tests admin review and approve/deny of parent drop requests.

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
use Registry::DAO::DropRequest;
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
    name => 'Admin Drop Studio', slug => 'admin-drop-studio',
    address_info => { street => '1 Main', city => 'Orlando', state => 'FL' },
    metadata => {},
});

my $program = $dao->create(Project => {
    name => 'Admin Drop Camp', program_type_slug => 'summer-camp', metadata => {},
});

my $teacher = $dao->create(User => { username => 'adrop_teacher', user_type => 'staff' });

my $session = $dao->create(Session => {
    name => 'Admin Drop Week 1', start_date => '2026-06-01', end_date => '2026-06-05',
    status => 'published', capacity => 16, metadata => {},
});

my $event = $dao->create(Event => {
    time => '2026-06-01 09:00:00', duration => 420,
    location_id => $location->id, project_id => $program->id,
    teacher_id => $teacher->id, capacity => 16, metadata => {},
});
$session->add_events($dao->db, $event->id);

my $parent = $dao->create(User => {
    username => 'adrop_parent', name => 'Admin Drop Parent',
    user_type => 'parent', email => 'adrop@example.com',
});

my $child = Registry::DAO::Family->add_child($dao->db, $parent->id, {
    child_name => 'Admin Drop Kid', birth_date => '2018-01-01', grade => '3',
    medical_info => {}, emergency_contact => { name => 'P', phone => '555' },
});

my $enrollment = Registry::DAO::Enrollment->create($dao->db, {
    session_id       => $session->id,
    family_member_id => $child->id,
    parent_id        => $parent->id,
    status           => 'active',
});

my $admin = $dao->create(User => {
    username => 'adrop_admin', name => 'Admin User',
    user_type => 'admin', email => 'adrop_admin@example.com',
});

# Create a pending drop request
my $drop_request = Registry::DAO::DropRequest->create($dao->db, {
    enrollment_id    => $enrollment->id,
    requested_by     => $parent->id,
    reason           => 'Family emergency requiring schedule change',
    refund_requested => 1,
    status           => 'pending',
});

ok $drop_request, 'Drop request created';

my ($workflow) = $dao->find(Workflow => { slug => 'admin-drop-approval' });
ok $workflow, 'admin-drop-approval workflow exists';

# ============================================================
# Test: Admin approve drop request
# ============================================================
subtest 'admin approves drop request' => sub {
    # Start the workflow with drop_request_id
    my $start_url = workflow_url($workflow);
    $t->post_ok($start_url => form => {
        drop_request_id => $drop_request->id,
    })->status_is(302);

    my $run = $workflow->latest_run($dao->db);
    ok $run, 'Workflow run created';

    # The start_workflow processes load-request, so next step should be review-request
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    my $step = $run->next_step($dao->db);

    # Navigate to admin-decision step
    while ($step && $step->slug ne 'admin-decision') {
        my $step_url = workflow_process_step_url($workflow, $run, $step);
        $t->post_ok($step_url => form => {})->status_is(302);
        ($run) = $dao->find(WorkflowRun => { id => $run->id });
        $step = $run->next_step($dao->db);
    }

    ok $step, 'Reached a step';
    is $step->slug, 'admin-decision', 'At admin-decision step';

    # Approve the drop request
    my $step_url = workflow_process_step_url($workflow, $run, $step);
    my $redirect = $t->post_ok($step_url => form => {
        action       => 'approve',
        admin_notes  => 'Approved due to family emergency',
        refund_amount => 300,
    })->status_is(302)->tx->res->headers->location;

    ok $redirect, 'Redirected after approval';

    # Verify the run data has the decision
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    is $run->data->{action}, 'approve', 'Decision stored as approve';
    like $run->data->{admin_notes}, qr/emergency/, 'Admin notes stored';
};

# ============================================================
# Test: Admin deny drop request
# ============================================================
subtest 'admin denies drop request' => sub {
    # Create another child and enrollment for denial test
    my $child2 = Registry::DAO::Family->add_child($dao->db, $parent->id, {
        child_name => 'Admin Drop Kid 2', birth_date => '2019-06-01', grade => '2',
        medical_info => {}, emergency_contact => { name => 'P', phone => '555' },
    });

    my $enrollment2 = Registry::DAO::Enrollment->create($dao->db, {
        session_id       => $session->id,
        family_member_id => $child2->id,
        parent_id        => $parent->id,
        status           => 'active',
    });

    my $drop_request2 = Registry::DAO::DropRequest->create($dao->db, {
        enrollment_id    => $enrollment2->id,
        requested_by     => $parent->id,
        reason           => 'Changed my mind about camp',
        refund_requested => 0,
        status           => 'pending',
    });

    # Start workflow
    $t->post_ok(workflow_url($workflow) => form => {
        drop_request_id => $drop_request2->id,
    })->status_is(302);

    my $run = $workflow->latest_run($dao->db);

    # Navigate to admin-decision
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    my $step = $run->next_step($dao->db);

    while ($step && $step->slug ne 'admin-decision') {
        $t->post_ok(workflow_process_step_url($workflow, $run, $step) => form => {})
          ->status_is(302);
        ($run) = $dao->find(WorkflowRun => { id => $run->id });
        $step = $run->next_step($dao->db);
    }

    is $step->slug, 'admin-decision', 'At admin-decision step';

    # Deny the request
    my $redirect = $t->post_ok(workflow_process_step_url($workflow, $run, $step) => form => {
        action      => 'deny',
        admin_notes => 'Camp has already started, no cancellations allowed',
    })->status_is(302)->tx->res->headers->location;

    ok $redirect, 'Redirected after denial';

    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    is $run->data->{action}, 'deny', 'Decision stored as deny';
};

done_testing;
