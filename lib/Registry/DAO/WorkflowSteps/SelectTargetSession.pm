use 5.42.0;
use Object::Pad;

class Registry::DAO::WorkflowSteps::SelectTargetSession :isa(Registry::DAO::WorkflowStep) {


    method process($db, $form_data, $run = undef) {
        $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };
        my $run_data = $run->data;
        my $enrollment_id = $run_data->{enrollment_id} or die "Enrollment ID required";

        # If target_session_id is provided, validate and proceed
        if (my $target_session_id = $form_data->{target_session_id}) {
            # Validate target session
            my $target_session = Registry::DAO::Session->find($db, { id => $target_session_id });
            return { errors => ['Target session not found'] } unless $target_session;

            # Check if target session has capacity
            my $enrollment_count = Registry::DAO::Enrollment->count_for_session($db, $target_session_id, ['active', 'pending']);
            if ($target_session->capacity && $enrollment_count >= $target_session->capacity) {
                return { errors => ['Target session is full'] };
            }

            # Store target session data for next steps (plain data, not objects)
            return {
                next_step           => 'collect-reason',
                target_session_id   => $target_session_id,
                target_session_name => $target_session->name,
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