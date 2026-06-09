# ABOUTME: Workflow step to process admin decision and trigger the appropriate transfer request workflow
# ABOUTME: Starts the transfer-request-processing workflow with admin decision data
use 5.42.0;
use Object::Pad;

require Registry::DAO::WorkflowStep;
require Registry::DAO::Workflow;

class Registry::DAO::WorkflowSteps::ProcessAdminTransferDecision :isa(Registry::DAO::WorkflowStep) {

    method process ($db, $data, $run = undef) {
        my $action = $data->{action};
        my $admin_notes = $data->{admin_notes};
        my $transfer_request_id = $data->{transfer_request_id};
        my $admin_user_id = $data->{admin_user_id};

        # Prepare data for the transfer-request-processing workflow
        my $processing_data = {
            transfer_request_id => $transfer_request_id,
            action => $action,
            admin_notes => $admin_notes,
            admin_user_id => $admin_user_id,
            admin_approved => 1  # Flag to indicate this came from admin approval
        };

        # Start the transfer-request-processing workflow
        require Registry::Utility::WorkflowProcessor;
        my $processor = Registry::WorkflowProcessor->new(dao => $db);

        my $workflow_obj = Registry::DAO::Workflow->find($db, { slug => 'transfer-request-processing' });
        my $workflow_run = $processor->new_run($workflow_obj, $processing_data);

        return {
            status => 'success',
            template_data => {
                action => $action,
                transfer_request_id => $transfer_request_id,
                workflow_run => $workflow_run->id,
                message => $action eq 'approve'
                    ? 'Transfer request approved and processing started'
                    : 'Transfer request denied and parent will be notified'
            },
            next_step => 'complete'
        };
    }
}