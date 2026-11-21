#!/usr/bin/env perl
# ABOUTME: Tests for ProcessAdminTransferDecision and ProcessAdminDropDecision workflow steps.
# ABOUTME: Verifies that each step correctly starts the downstream processing workflow via WorkflowProcessor.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Mojo::File qw(path);
use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::DAO::User;
use Registry::DAO::Session;
use Registry::DAO::Enrollment;
use Registry::DAO::TransferRequest;
use Registry::DAO::WorkflowSteps::ProcessAdminTransferDecision;
use Registry::DAO::WorkflowSteps::ProcessAdminDropDecision;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# Import all workflows so transfer-request-processing and drop-request-processing exist.
my @workflow_files = path('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
$dao->import_workflows(\@workflow_files);

# Confirm the target workflows were imported.
my $transfer_proc_wf = Registry::DAO::Workflow->find($db, { slug => 'transfer-request-processing' });
my $drop_proc_wf     = Registry::DAO::Workflow->find($db, { slug => 'drop-request-processing' });

ok $transfer_proc_wf, 'transfer-request-processing workflow present in database';
ok $drop_proc_wf,     'drop-request-processing workflow present in database';

# -- Shared test fixtures -------------------------------------------------------

my $parent_user = Registry::DAO::User->create($db, {
    username  => 'admin_decision_parent',
    user_type => 'parent',
    email     => 'parent@admin-decision.test',
    name      => 'Admin Decision Parent',
});

my $admin_user = Registry::DAO::User->create($db, {
    username  => 'admin_decision_admin',
    user_type => 'admin',
    email     => 'admin@admin-decision.test',
    name      => 'Admin Decision Admin',
});

my $source_session = Registry::DAO::Session->create($db, {
    name       => 'Admin Decision Source Session',
    start_date => '2024-01-01',
    end_date   => '2024-01-15',
    capacity   => 10,
});

my $target_session = Registry::DAO::Session->create($db, {
    name       => 'Admin Decision Target Session',
    start_date => '2024-02-01',
    end_date   => '2024-02-15',
    capacity   => 10,
});

my $family_member = $dao->create(FamilyMember => {
    family_id  => $parent_user->id,
    child_name => 'Admin Decision Child',
    birth_date => '2010-01-01',
    grade      => '5th',
});

# -- ProcessAdminTransferDecision -----------------------------------------------

subtest 'ProcessAdminTransferDecision starts transfer-request-processing workflow run' => sub {
    my $enrollment = Registry::DAO::Enrollment->create($db, {
        session_id       => $source_session->id,
        student_id       => $family_member->id,
        family_member_id => $family_member->id,
        parent_id        => $parent_user->id,
        status           => 'active',
    });

    my $transfer_request = Registry::DAO::TransferRequest->create($db, {
        enrollment_id     => $enrollment->id,
        target_session_id => $target_session->id,
        requested_by      => $parent_user->id,
        reason            => 'Schedule conflict',
    });

    my $step = Registry::DAO::WorkflowSteps::ProcessAdminTransferDecision->new(
        id          => 0,
        slug        => 'process-admin-transfer-decision',
        description => 'test',
        workflow_id => 0,
        class       => 'Registry::DAO::WorkflowSteps::ProcessAdminTransferDecision',
    );

    my $result = eval {
        $step->process($db, {
            action              => 'approve',
            admin_notes         => 'Looks good',
            transfer_request_id => $transfer_request->id,
            admin_user_id       => $admin_user->id,
        });
    };
    my $err = $@;
    ok !$err, "ProcessAdminTransferDecision->process does not die"
        or diag("Error: $err");

    is $result->{status}, 'success', 'result status is success';
    ok $result->{template_data}{workflow_run}, 'workflow_run id present in template_data';
    is $result->{next_step}, 'complete', 'next_step is complete';

    # Verify a WorkflowRun was actually created for the processing workflow.
    my $run = Registry::DAO::WorkflowRun->find($db, { id => $result->{template_data}{workflow_run} });
    ok $run, 'a WorkflowRun row exists for the returned id';
    is $run->workflow_id, $transfer_proc_wf->id,
        'the created run belongs to transfer-request-processing workflow';
};

# -- ProcessAdminDropDecision ---------------------------------------------------

subtest 'ProcessAdminDropDecision starts drop-request-processing workflow run' => sub {
    # Use a separate family member so there is no unique-constraint collision
    # with the enrollment created in the transfer-decision subtest above.
    my $drop_family_member = $dao->create(FamilyMember => {
        family_id  => $parent_user->id,
        child_name => 'Admin Drop Child',
        birth_date => '2011-03-15',
        grade      => '4th',
    });

    my $enrollment = Registry::DAO::Enrollment->create($db, {
        session_id       => $source_session->id,
        student_id       => $drop_family_member->id,
        family_member_id => $drop_family_member->id,
        parent_id        => $parent_user->id,
        status           => 'active',
    });

    # Request a drop (started session, so requires admin approval)
    my $drop_request = $enrollment->request_drop($db, $parent_user,
        'Family moving away', 1);

    ok $drop_request, 'drop_request created for test setup';

    my $step = Registry::DAO::WorkflowSteps::ProcessAdminDropDecision->new(
        id          => 0,
        slug        => 'process-admin-drop-decision',
        description => 'test',
        workflow_id => 0,
        class       => 'Registry::DAO::WorkflowSteps::ProcessAdminDropDecision',
    );

    my $result = eval {
        $step->process($db, {
            action          => 'approve',
            admin_notes     => 'Approved',
            refund_amount   => 50,
            drop_request_id => $drop_request->id,
            admin_user_id   => $admin_user->id,
        });
    };
    my $err = $@;
    ok !$err, "ProcessAdminDropDecision->process does not die"
        or diag("Error: $err");

    is $result->{status}, 'success', 'result status is success';
    ok $result->{template_data}{workflow_run}, 'workflow_run id present in template_data';
    is $result->{next_step}, 'complete', 'next_step is complete';

    my $run = Registry::DAO::WorkflowRun->find($db, { id => $result->{template_data}{workflow_run} });
    ok $run, 'a WorkflowRun row exists for the returned id';
    is $run->workflow_id, $drop_proc_wf->id,
        'the created run belongs to drop-request-processing workflow';
};

done_testing;
