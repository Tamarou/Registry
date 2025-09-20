use 5.40.2;
use Object::Pad;

class Registry::DAO::WorkflowSteps::ReviewDropRequest :isa(Registry::DAO::WorkflowStep) {
    use experimental qw(try);

    method process($db, $form_data, $run_data = {}) {
        # If user confirms, proceed to submission
        if ($form_data->{confirm}) {
            return {
                next_step => 'submit-request'
            };
        }

        my $enrollment = $run_data->{enrollment};
        my $user = $run_data->{user};

        # Determine if this will be an immediate drop or require admin approval
        my $can_drop_immediately = $enrollment->can_drop($db, $user);

        # Show review page with all collected data
        return {
            template_data => {
                enrollment => $enrollment,
                family_member => $run_data->{family_member},
                reason => $run_data->{reason},
                refund_requested => $run_data->{refund_requested},
                can_drop_immediately => $can_drop_immediately
            }
        };
    }
}