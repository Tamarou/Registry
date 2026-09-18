use 5.42.0;
use Object::Pad;

class Registry::DAO::WorkflowSteps::SubmitTransferRequest :isa(Registry::DAO::WorkflowStep) {


    method process($db, $form_data, $run = undef) {
        $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };
        my $run_data = $run->data;

        try {
            my $user = $run_data->{user} or die "User required for transfer request submission";
            my $enrollment_id = $run_data->{enrollment_id} or die "Enrollment ID required";
            my $target_session_id = $run_data->{target_session_id} or die "Target session ID required";
            my $reason = $run_data->{reason} or die "Reason required";

            my $result = Registry::DAO::TransferRequest->request_for_enrollment(
                $db, $enrollment_id, $target_session_id, $user, $reason
            );

            if ($result->{error}) {
                return { errors => [$result->{error}] };
            }

            # Store transfer request ID (not the object -- objects can't serialize to JSONB)
            my $transfer_request = $result->{transfer_request};

            return {
                next_step           => 'complete',
                transfer_request_id => $transfer_request ? $transfer_request->id : undef,
                success_message     => 'Transfer request submitted successfully for admin approval',
            };
        }
        catch ($e) {
            # Say what actually went wrong somewhere a developer can read it.
            # Swallowing $e is how a missing class load looked identical to a
            # rejected request for as long as it did: the parent was told to
            # contact support, and nothing anywhere recorded the reason.
            warn "transfer request submission failed: $e";
            return { errors => ["Failed to submit transfer request. Please try again or contact support."] };
        }
    }
}
