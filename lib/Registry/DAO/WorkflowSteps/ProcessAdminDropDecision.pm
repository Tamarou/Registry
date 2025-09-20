# ABOUTME: Workflow step to process admin decision and trigger the appropriate drop request workflow
# ABOUTME: Starts the drop-request-processing workflow with admin decision data
use 5.40.2;
use Object::Pad;

require Registry::DAO::WorkflowStep;

class Registry::DAO::WorkflowSteps::ProcessAdminDropDecision :isa(Registry::DAO::WorkflowStep) {

    method process ($db, $data) {
        my $action = $data->{action};
        my $admin_notes = $data->{admin_notes};
        my $refund_amount = $data->{refund_amount};
        my $drop_request_id = $data->{drop_request_id};
        my $admin_user_id = $data->{admin_user_id};

        # Prepare data for the drop-request-processing workflow
        my $processing_data = {
            drop_request_id => $drop_request_id,
            action => $action,
            admin_notes => $admin_notes,
            refund_amount => $refund_amount,
            admin_user_id => $admin_user_id,
            admin_approved => 1  # Flag to indicate this came from admin approval
        };

        # Start the drop-request-processing workflow
        require Registry::Utility::WorkflowProcessor;
        my $processor = Registry::Utility::WorkflowProcessor->new($db);

        my $workflow_run = $processor->new_run('drop-request-processing', $processing_data);

        return {
            status => 'success',
            template_data => {
                action => $action,
                drop_request_id => $drop_request_id,
                workflow_run => $workflow_run->id,
                message => $action eq 'approve'
                    ? 'Drop request approved and processing started'
                    : 'Drop request denied and parent will be notified'
            },
            next_step => 'complete'
        };
    }
}