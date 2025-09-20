use 5.40.2;
use Object::Pad;

class Registry::DAO::WorkflowSteps::SubmitTransferRequest :isa(Registry::DAO::WorkflowStep) {
    use experimental qw(try);

    method process($db, $form_data, $run_data = {}) {
        my $user = $run_data->{user} or die "User required for transfer request submission";
        my $enrollment_id = $run_data->{enrollment_id} or die "Enrollment ID required";
        my $target_session_id = $run_data->{target_session_id} or die "Target session ID required";
        my $reason = $run_data->{reason} or die "Reason required";

        try {
            # Use the DAO method we created earlier to submit the transfer request
            my $result = Registry::DAO::TransferRequest->request_for_enrollment(
                $db, $enrollment_id, $target_session_id, $user, $reason
            );

            if ($result->{error}) {
                return { error => $result->{error} };
            }

            # Queue admin notification job
            # Note: This would need access to the Minion job queue
            # For now, we'll store the transfer request and handle notification separately
            my $transfer_request = $result->{transfer_request};

            return {
                next_step => 'complete',
                data => {
                    transfer_request => $transfer_request,
                    success_message => 'Transfer request submitted successfully for admin approval'
                }
            };
        }
        catch ($e) {
            return { error => "Failed to submit transfer request: $e" };
        }
    }
}