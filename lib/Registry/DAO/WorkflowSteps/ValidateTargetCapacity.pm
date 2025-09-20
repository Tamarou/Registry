# ABOUTME: Validates target session has available capacity for transfer
# ABOUTME: Checks session capacity limits and current enrollment count
use 5.40.2;
use utf8;
use Object::Pad;

class Registry::DAO::WorkflowSteps::ValidateTargetCapacity :isa(Registry::DAO::WorkflowStep) {
    use Carp qw(confess);

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my ($run)      = $workflow->latest_run($db);
        my $data       = $run->data;

        my $target_session_id = $data->{target_session_id}
            or confess "target_session_id is required for capacity validation";

        # Load target session
        my $target_session = Registry::DAO::Session->find($db, { id => $target_session_id })
            or confess "Target session $target_session_id not found";

        # Check capacity if session has a limit
        if ($target_session->capacity) {
            my $current_enrollment_count = Registry::DAO::Enrollment->count_for_session(
                $db, $target_session_id, ['active', 'pending']
            );

            if ($current_enrollment_count >= $target_session->capacity) {
                confess "Target session is at full capacity ($current_enrollment_count/" . $target_session->capacity . ")";
            }
        }

        return {
            capacity_validated => 1,
            target_session_capacity => $target_session->capacity,
            current_enrollment_count => Registry::DAO::Enrollment->count_for_session(
                $db, $target_session_id, ['active', 'pending']
            )
        };
    }
}