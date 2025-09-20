# ABOUTME: Processes the actual enrollment transfer between sessions
# ABOUTME: Updates enrollment session and transfer status with admin tracking
use 5.40.2;
use utf8;
use Object::Pad;

class Registry::DAO::WorkflowSteps::ProcessEnrollmentTransfer :isa(Registry::DAO::WorkflowStep) {
    use Carp qw(confess);
    use Scalar::Util qw(blessed);

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my ($run)      = $workflow->latest_run($db);
        my $data       = $run->data;

        my $enrollment_id = $data->{enrollment_id}
            or confess "enrollment_id is required for enrollment transfer processing";

        my $target_session_id = $data->{target_session_id}
            or confess "target_session_id is required for enrollment transfer processing";

        # Load enrollment
        my $enrollment = Registry::DAO::Enrollment->find($db, { id => $enrollment_id })
            or confess "Enrollment $enrollment_id not found";

        # Extract admin user info
        my $admin_user = $data->{admin_user};
        my $admin_id = blessed($admin_user) ? $admin_user->id : $admin_user->{id};

        # Store original session for waitlist processing
        my $original_session_id = $enrollment->session_id;

        # Update enrollment to new session
        $enrollment->update($db, {
            session_id => $target_session_id,
            transfer_to_session_id => $target_session_id,
            transfer_status => 'completed'
        });

        return {
            enrollment_transferred => 1,
            original_session_id => $original_session_id,
            target_session_id => $target_session_id,
            processed_by => $admin_id
        };
    }
}