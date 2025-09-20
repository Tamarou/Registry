# ABOUTME: Workflow step to load and validate a drop request for admin review
# ABOUTME: Ensures the drop request exists and is in a valid state for processing
use 5.40.2;
use Object::Pad;

require Registry::DAO::WorkflowStep;

class Registry::DAO::WorkflowSteps::LoadDropRequest :isa(Registry::DAO::WorkflowStep) {

    method process ($db, $data) {
        my $drop_request_id = $data->{drop_request_id}
            or confess "drop_request_id is required for drop request processing";

        # Load the drop request
        require Registry::DAO::DropRequest;
        my $drop_request = Registry::DAO::DropRequest->find($db, { id => $drop_request_id });

        unless ($drop_request) {
            confess "Drop request not found: $drop_request_id";
        }

        # Verify it's in pending status
        if ($drop_request->status ne 'pending') {
            confess "Drop request has already been processed: " . $drop_request->status;
        }

        # Get detailed request information
        my $detailed_requests = Registry::DAO::DropRequest->get_detailed_requests($db, 'pending', undef, $drop_request_id);
        my $request_details = $detailed_requests->[0];

        unless ($request_details) {
            confess "Could not load detailed drop request information";
        }

        return {
            status => 'success',
            template_data => {
                drop_request => $request_details,
                drop_request_id => $drop_request_id
            },
            next_step => 'review-request'
        };
    }
}