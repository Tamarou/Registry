use 5.40.2;
use Object::Pad;

class Registry::DAO::WorkflowSteps::CollectTransferReason :isa(Registry::DAO::WorkflowStep) {
    use experimental qw(try);

    method process($db, $form_data, $run_data = {}) {
        # If reason is provided, validate and proceed
        if (my $reason = $form_data->{reason}) {
            $reason =~ s/^\s+|\s+$//g; # trim whitespace

            return { error => 'Please provide a reason for the transfer request' } if length($reason) < 10;
            return { error => 'Reason is too long (maximum 500 characters)' } if length($reason) > 500;

            return {
                next_step => 'review-request',
                data => {
                    reason => $reason
                }
            };
        }

        # Show form to collect reason
        return {
            template_data => {
                enrollment => $run_data->{enrollment},
                target_session => $run_data->{target_session}
            }
        };
    }
}