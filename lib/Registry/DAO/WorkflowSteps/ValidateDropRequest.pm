# ABOUTME: Validates drop request eligibility and enrollment status
# ABOUTME: Ensures drop request exists and enrollment is in valid state for dropping
use 5.40.2;
use utf8;
use Object::Pad;

class Registry::DAO::WorkflowSteps::ValidateDropRequest :isa(Registry::DAO::WorkflowStep) {
    use Carp qw(confess);

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my ($run)      = $workflow->latest_run($db);
        my $data       = $run->data;

        # Validate required data
        my $drop_request_id = $data->{drop_request_id}
            or confess "drop_request_id is required for drop request processing";

        # Load drop request
        my $drop_request = Registry::DAO::DropRequest->find($db, { id => $drop_request_id })
            or confess "Drop request $drop_request_id not found";

        # Load enrollment
        my $enrollment = $drop_request->enrollment($db)
            or confess "Enrollment for drop request $drop_request_id not found";

        # Validate enrollment is in droppable state
        unless ($enrollment->status eq 'active' || $enrollment->status eq 'pending') {
            confess "Enrollment must be active or pending to be dropped, current status: " . $enrollment->status;
        }

        # Validate drop request is pending
        unless ($drop_request->status eq 'pending') {
            confess "Drop request must be pending to be processed, current status: " . $drop_request->status;
        }

        return {
            drop_request_id => $drop_request_id,
            enrollment_id => $enrollment->id,
            session_id => $enrollment->session_id,
            validation_passed => 1
        };
    }
}