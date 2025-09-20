# ABOUTME: Validates transfer request eligibility and enrollment status
# ABOUTME: Ensures transfer request exists and enrollment is in valid state for transfer
use 5.40.2;
use utf8;
use Object::Pad;

class Registry::DAO::WorkflowSteps::ValidateTransferRequest :isa(Registry::DAO::WorkflowStep) {
    use Carp qw(confess);

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my ($run)      = $workflow->latest_run($db);
        my $data       = $run->data;

        # Validate required data
        my $transfer_request_id = $data->{transfer_request_id}
            or confess "transfer_request_id is required for transfer request processing";

        # Load transfer request
        my $transfer_request = Registry::DAO::TransferRequest->find($db, { id => $transfer_request_id })
            or confess "Transfer request $transfer_request_id not found";

        # Load enrollment
        my $enrollment = $transfer_request->enrollment($db)
            or confess "Enrollment for transfer request $transfer_request_id not found";

        # Load target session
        my $target_session = $transfer_request->to_session($db)
            or confess "Target session for transfer request $transfer_request_id not found";

        # Validate enrollment is in transferable state
        unless ($enrollment->status eq 'active') {
            confess "Enrollment must be active to be transferred, current status: " . $enrollment->status;
        }

        # Validate transfer request is pending
        unless ($transfer_request->status eq 'pending') {
            confess "Transfer request must be pending to be processed, current status: " . $transfer_request->status;
        }

        return {
            transfer_request_id => $transfer_request_id,
            enrollment_id => $enrollment->id,
            source_session_id => $enrollment->session_id,
            target_session_id => $transfer_request->target_session_id,
            validation_passed => 1
        };
    }
}