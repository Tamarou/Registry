use 5.42.0;
use Object::Pad;

class Registry::DAO::WorkflowSteps::ReviewTransferRequest :isa(Registry::DAO::WorkflowStep) {

    use Registry::DAO::Enrollment;
    use Registry::DAO::Session;

    method process($db, $form_data, $run = undef) {
        $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };
        my $run_data = $run->data;

        # If user confirms, proceed to submission
        if ($form_data->{confirm}) {
            return {
                next_step => 'submit-request'
            };
        }

        # Load objects from stored IDs (not stored as objects)
        my $enrollment = $run_data->{enrollment_id}
            ? Registry::DAO::Enrollment->find($db, { id => $run_data->{enrollment_id} })
            : undef;

        my $target_session = $run_data->{target_session_id}
            ? Registry::DAO::Session->find($db, { id => $run_data->{target_session_id} })
            : undef;

        # Show review page with all collected data
        return {
            template_data => {
                enrollment          => $enrollment,
                target_session      => $target_session,
                target_session_name => $run_data->{target_session_name},
                child_name          => $run_data->{child_name},
                reason              => $run_data->{reason},
            }
        };
    }
}
