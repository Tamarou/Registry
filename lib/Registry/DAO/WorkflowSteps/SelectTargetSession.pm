use 5.40.2;
use Object::Pad;

class Registry::DAO::WorkflowSteps::SelectTargetSession :isa(Registry::DAO::WorkflowStep) {
    use experimental qw(try);

    method process($db, $form_data, $run_data = {}) {
        my $enrollment_id = $run_data->{enrollment_id} or die "Enrollment ID required";

        # If target_session_id is provided, validate and proceed
        if (my $target_session_id = $form_data->{target_session_id}) {
            # Validate target session
            my $target_session = Registry::DAO::Session->find($db, { id => $target_session_id });
            return { error => 'Target session not found' } unless $target_session;

            # Check if target session has capacity
            my $enrollment_count = Registry::DAO::Enrollment->count_for_session($db, $target_session_id, ['active', 'pending']);
            if ($target_session->capacity && $enrollment_count >= $target_session->capacity) {
                return { error => 'Target session is full' };
            }

            # Store target session data for next steps
            return {
                next_step => 'collect-reason',
                data => {
                    target_session_id => $target_session_id,
                    target_session => $target_session
                }
            };
        }

        # Get available sessions for transfer
        my $current_enrollment = Registry::DAO::Enrollment->find($db, { id => $enrollment_id });
        my $available_sessions = Registry::DAO::Session->get_available_for_transfer($db, $current_enrollment->session_id);

        return {
            template_data => {
                current_enrollment => $current_enrollment,
                available_sessions => $available_sessions
            }
        };
    }
}