# ABOUTME: Processes refund for dropped enrollment if requested
# ABOUTME: Handles refund calculation and triggers payment processing workflow if needed
use 5.40.2;
use utf8;
use Object::Pad;

class Registry::DAO::WorkflowSteps::ProcessDropRefund :isa(Registry::DAO::WorkflowStep) {

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my ($run)      = $workflow->latest_run($db);
        my $data       = $run->data;

        # Only process if refund was requested
        unless ($data->{refund_requested}) {
            return { refund_processed => 0, message => 'No refund requested' };
        }

        # TODO: Integrate with payment processing workflow
        # For now, we'll just mark the refund as pending
        # In a full implementation, this would:
        # 1. Calculate refund amount based on program rules
        # 2. Trigger payment processing workflow
        # 3. Update payment records

        return {
            refund_processed => 1,
            refund_amount => $data->{refund_amount},
            refund_status => 'pending',
            message => 'Refund marked as pending for payment processing'
        };
    }
}