use 5.42.0;
use Object::Pad;

class Registry::DAO::WorkflowSteps::SubmitDropRequest :isa(Registry::DAO::WorkflowStep) {


    method process($db, $form_data) {
        my $workflow = $self->workflow($db);
        my $run = $workflow->latest_run($db);
        my $run_data = $run->data;

        try {
            my $user = $run_data->{user} or die "User required for drop request submission";
            my $enrollment_id = $run_data->{enrollment_id} or die "Enrollment ID required";
            my $reason = $run_data->{reason} or die "Reason required";
            my $refund_requested = $run_data->{refund_requested} // 0;

            my $result = Registry::DAO::DropRequest->request_for_enrollment(
                $db, $enrollment_id, $user, $reason, $refund_requested
            );

            if ($result->{error}) {
                return { errors => [$result->{error}] };
            }

            my $return = {
                next_step       => 'complete',
                success_message => $result->{message},
                immediate_drop  => $result->{immediate},
            };

            # Store drop request ID (not the object -- objects can't serialize to JSONB)
            if ($result->{drop_request}) {
                $return->{drop_request_id} = $result->{drop_request}->id;
            }

            return $return;
        }
        catch ($e) {
            return { errors => ["Failed to submit drop request. Please try again or contact support."] };
        }
    }
}
