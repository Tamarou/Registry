# ABOUTME: Workflow step to collect admin decision (approve/deny) and notes for transfer request
# ABOUTME: Validates admin input and prepares data for processing the decision
use 5.40.2;
use Object::Pad;

require Registry::DAO::WorkflowStep;

class Registry::DAO::WorkflowSteps::AdminTransferDecision :isa(Registry::DAO::WorkflowStep) {

    method process ($db, $data) {
        my $action = $data->{action};
        my $admin_notes = $data->{admin_notes} || '';

        # If no action provided, show form
        unless ($action && ($action eq 'approve' || $action eq 'deny')) {
            return {
                status => 'form',
                template_data => {
                    transfer_request_id => $data->{transfer_request_id},
                    transfer_request => $data->{transfer_request}
                }
            };
        }

        # Decision collected successfully
        return {
            status => 'success',
            template_data => {
                action => $action,
                admin_notes => $admin_notes,
                transfer_request_id => $data->{transfer_request_id}
            },
            next_step => 'process-decision'
        };
    }
}