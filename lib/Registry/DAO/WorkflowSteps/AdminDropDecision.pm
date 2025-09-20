# ABOUTME: Workflow step to collect admin decision (approve/deny) and notes for drop request
# ABOUTME: Validates admin input and prepares data for processing the decision
use 5.40.2;
use Object::Pad;

require Registry::DAO::WorkflowStep;

class Registry::DAO::WorkflowSteps::AdminDropDecision :isa(Registry::DAO::WorkflowStep) {

    method process ($db, $data) {
        my $action = $data->{action};
        my $admin_notes = $data->{admin_notes} || '';
        my $refund_amount = $data->{refund_amount};

        # If no action provided, show form
        unless ($action && ($action eq 'approve' || $action eq 'deny')) {
            return {
                status => 'form',
                template_data => {
                    drop_request_id => $data->{drop_request_id},
                    drop_request => $data->{drop_request}
                }
            };
        }

        # Validate refund amount for approvals
        if ($action eq 'approve' && defined $refund_amount) {
            unless ($refund_amount =~ /^\d+(\.\d{2})?$/ && $refund_amount >= 0) {
                return {
                    status => 'form',
                    template_data => {
                        drop_request_id => $data->{drop_request_id},
                        drop_request => $data->{drop_request},
                        error => 'Invalid refund amount. Please enter a valid dollar amount.'
                    }
                };
            }
        }

        # Decision collected successfully
        return {
            status => 'success',
            template_data => {
                action => $action,
                admin_notes => $admin_notes,
                refund_amount => $refund_amount,
                drop_request_id => $data->{drop_request_id}
            },
            next_step => 'process-decision'
        };
    }
}