use 5.40.2;
use Object::Pad;

class Registry::DAO::WorkflowSteps::ReviewTransferRequest :isa(Registry::DAO::WorkflowStep) {
    use experimental qw(try);

    method process($db, $form_data, $run_data = {}) {
        # If user confirms, proceed to submission
        if ($form_data->{confirm}) {
            return {
                next_step => 'submit-request'
            };
        }

        # Show review page with all collected data
        return {
            template_data => {
                enrollment => $run_data->{enrollment},
                target_session => $run_data->{target_session},
                family_member => $run_data->{family_member},
                reason => $run_data->{reason}
            }
        };
    }
}