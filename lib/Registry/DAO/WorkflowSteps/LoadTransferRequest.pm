# ABOUTME: Workflow step to load and validate a transfer request for admin review
# ABOUTME: Ensures the transfer request exists and is in a valid state for processing
use 5.40.2;
use Object::Pad;

require Registry::DAO::WorkflowStep;

class Registry::DAO::WorkflowSteps::LoadTransferRequest :isa(Registry::DAO::WorkflowStep) {
    use Carp qw(confess);

    method process ($db, $data) {
        my $transfer_request_id = $data->{transfer_request_id}
            or confess "transfer_request_id is required for transfer request processing";

        # Load the transfer request
        require Registry::DAO::TransferRequest;
        my $transfer_request = Registry::DAO::TransferRequest->find($db, { id => $transfer_request_id });

        unless ($transfer_request) {
            confess "Transfer request not found: $transfer_request_id";
        }

        # Verify it's in pending status
        if ($transfer_request->status ne 'pending') {
            confess "Transfer request has already been processed: " . $transfer_request->status;
        }

        # Get detailed request information
        my $detailed_requests = Registry::DAO::TransferRequest->get_detailed_requests($db, 'pending', undef, $transfer_request_id);
        my $request_details = $detailed_requests->[0];

        unless ($request_details) {
            confess "Could not load detailed transfer request information";
        }

        return {
            status => 'success',
            template_data => {
                transfer_request => $request_details,
                transfer_request_id => $transfer_request_id
            },
            next_step => 'review-request'
        };
    }
}