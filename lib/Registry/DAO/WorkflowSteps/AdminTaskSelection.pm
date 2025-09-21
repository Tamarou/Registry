# ABOUTME: Workflow step for admin to select and continue with pending administrative tasks
# ABOUTME: Handles continuation to drop/transfer approval workflows and other admin actions
use 5.40.2;
use Object::Pad;

require Registry::DAO::WorkflowStep;

class Registry::DAO::WorkflowSteps::AdminTaskSelection :isa(Registry::DAO::WorkflowStep) {
    use Carp qw(confess);

    method process ($db, $data) {
        my $task_type = $data->{task_type};
        my $task_id = $data->{task_id};

        # If no task selected, stay on dashboard
        unless ($task_type && $task_id) {
            return {
                status => 'form',
                template_data => {
                    available_tasks => $self->_get_available_tasks($db, $data->{current_user})
                }
            };
        }

        # Route to appropriate workflow based on task type
        if ($task_type eq 'drop_request') {
            return {
                status => 'continuation',
                workflow => 'admin-drop-approval',
                workflow_data => {
                    drop_request_id => $task_id,
                    admin_user_id => $data->{current_user}{id}
                }
            };
        } elsif ($task_type eq 'transfer_request') {
            return {
                status => 'continuation',
                workflow => 'admin-transfer-approval',
                workflow_data => {
                    transfer_request_id => $task_id,
                    admin_user_id => $data->{current_user}{id}
                }
            };
        }

        # Unknown task type
        confess "Unknown task type: $task_type";
    }

    method _get_available_tasks ($db, $user) {
        my @tasks;

        # Get pending drop requests
        require Registry::DAO::DropRequest;
        my $drop_requests = Registry::DAO::DropRequest->get_detailed_requests($db, 'pending', 10);
        for my $request (@$drop_requests) {
            push @tasks, {
                type => 'drop_request',
                id => $request->{id},
                title => "Drop Request: $request->{child_name}",
                description => "Requested by $request->{parent_name}",
                created_at => $request->{created_at}
            };
        }

        # Get pending transfer requests
        require Registry::DAO::TransferRequest;
        my $transfer_requests = Registry::DAO::TransferRequest->get_detailed_requests($db, 'pending');
        for my $request (@$transfer_requests) {
            push @tasks, {
                type => 'transfer_request',
                id => $request->{id},
                title => "Transfer Request: $request->{child_name}",
                description => "Requested by $request->{parent_name}",
                created_at => $request->{created_at}
            };
        }

        # Sort by creation date (newest first)
        return [sort { $b->{created_at} cmp $a->{created_at} } @tasks];
    }
}