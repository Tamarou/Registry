use 5.42.0;
use Object::Pad;

class Registry::DAO::WorkflowSteps::ReviewDropRequest :isa(Registry::DAO::WorkflowStep) {

    use Registry::DAO::Enrollment;

    method process($db, $form_data, $run = undef) {
        $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };
        my $run_data = $run->data;

        # If user confirms, proceed to submission
        if ($form_data->{confirm}) {
            return {
                next_step => 'submit-request'
            };
        }

        # Load enrollment from stored ID (not stored as an object)
        my $enrollment_id = $run_data->{enrollment_id};
        my $enrollment = $enrollment_id
            ? Registry::DAO::Enrollment->find($db, { id => $enrollment_id })
            : undef;

        my $user = $run_data->{user};

        # Determine if this will be an immediate drop or require admin approval
        my $can_drop_immediately = ($enrollment && $user)
            ? $enrollment->can_drop($db, $user)
            : 0;

        # Show review page with all collected data
        return {
            template_data => {
                enrollment           => $enrollment,
                child_name           => $run_data->{child_name},
                reason               => $run_data->{reason},
                refund_requested     => $run_data->{refund_requested},
                can_drop_immediately => $can_drop_immediately,
            }
        };
    }
}
