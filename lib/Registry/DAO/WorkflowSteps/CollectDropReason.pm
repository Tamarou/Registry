use 5.40.2;
use Object::Pad;

class Registry::DAO::WorkflowSteps::CollectDropReason :isa(Registry::DAO::WorkflowStep) {
    use experimental qw(try);

    method process($db, $form_data, $run_data = {}) {
        # If reason is provided, validate and proceed
        if (my $reason = $form_data->{reason}) {
            $reason =~ s/^\s+|\s+$//g; # trim whitespace

            return { error => 'Please provide a reason for the drop request' } if length($reason) < 10;
            return { error => 'Reason is too long (maximum 500 characters)' } if length($reason) > 500;

            # Handle refund request checkbox
            my $refund_requested = $form_data->{refund_requested} ? 1 : 0;

            return {
                next_step => 'review-request',
                data => {
                    reason => $reason,
                    refund_requested => $refund_requested
                }
            };
        }

        # Show form to collect reason and refund preference
        return {
            template_data => {
                enrollment => $run_data->{enrollment},
                family_member => $run_data->{family_member}
            }
        };
    }
}