use 5.40.2;
use Object::Pad;

class Registry::DAO::WorkflowSteps::SubmitDropRequest :isa(Registry::DAO::WorkflowStep) {
    use experimental qw(try);

    method process($db, $form_data, $run_data = {}) {
        my $user = $run_data->{user} or die "User required for drop request submission";
        my $enrollment_id = $run_data->{enrollment_id} or die "Enrollment ID required";
        my $reason = $run_data->{reason} or die "Reason required";
        my $refund_requested = $run_data->{refund_requested} // 0;

        try {
            # Use the DAO method we created earlier to submit the drop request
            my $result = Registry::DAO::DropRequest->request_for_enrollment(
                $db, $enrollment_id, $user, $reason, $refund_requested
            );

            if ($result->{error}) {
                return { error => $result->{error} };
            }

            # Store result data for completion page
            my $completion_data = {
                success_message => $result->{message},
                immediate_drop => $result->{immediate}
            };

            # If there's a drop request (not immediate), store it for potential admin notification
            if ($result->{drop_request}) {
                $completion_data->{drop_request} = $result->{drop_request};
            }

            return {
                next_step => 'complete',
                data => $completion_data
            };
        }
        catch ($e) {
            return { error => "Failed to submit drop request: $e" };
        }
    }
}