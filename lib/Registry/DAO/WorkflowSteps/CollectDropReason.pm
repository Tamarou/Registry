use 5.42.0;
use Object::Pad;

class Registry::DAO::WorkflowSteps::CollectDropReason :isa(Registry::DAO::WorkflowStep) {


    method process($db, $form_data, $run = undef) {
        $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };
        my $run_data = $run->data;
        # If reason is provided, validate and proceed
        if (my $reason = $form_data->{reason}) {
            $reason =~ s/^\s+|\s+$//g; # trim whitespace

            return { errors => ['Please provide a reason for the drop request'] } if length($reason) < 10;
            return { errors => ['Reason is too long (maximum 500 characters)'] } if length($reason) > 500;

            # Handle refund request checkbox
            my $refund_requested = $form_data->{refund_requested} ? 1 : 0;

            return {
                next_step        => 'review-request',
                reason           => $reason,
                refund_requested => $refund_requested
            };
        }

        # Show form to collect reason and refund preference
        return {
            template_data => {
                enrollment_id => $run_data->{enrollment_id},
                child_name    => $run_data->{child_name},
            }
        };
    }
}