# ABOUTME: Processes the actual enrollment drop by updating status and metadata
# ABOUTME: Cancels enrollment and records drop details including admin user and timestamp
use 5.40.2;
use utf8;
use Object::Pad;

class Registry::DAO::WorkflowSteps::ProcessEnrollmentDrop :isa(Registry::DAO::WorkflowStep) {
    use Carp qw(confess);
    use Scalar::Util qw(blessed);

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my ($run)      = $workflow->latest_run($db);
        my $data       = $run->data;

        my $enrollment_id = $data->{enrollment_id}
            or confess "enrollment_id is required for enrollment drop processing";

        my $drop_request_id = $data->{drop_request_id}
            or confess "drop_request_id is required for enrollment drop processing";

        # Load objects
        my $enrollment = Registry::DAO::Enrollment->find($db, { id => $enrollment_id })
            or confess "Enrollment $enrollment_id not found";

        my $drop_request = Registry::DAO::DropRequest->find($db, { id => $drop_request_id })
            or confess "Drop request $drop_request_id not found";

        # Extract admin user info
        my $admin_user = $data->{admin_user};
        my $admin_id = blessed($admin_user) ? $admin_user->id : $admin_user->{id};

        # Update enrollment status
        $enrollment->update($db, {
            status => 'cancelled',
            drop_reason => $data->{reason} || $drop_request->reason,
            dropped_at => \'now()',
            dropped_by => $admin_id,
            refund_status => $data->{refund_requested} ? 'pending' : 'none',
            refund_amount => $data->{refund_amount}
        });

        return {
            enrollment_cancelled => 1,
            refund_requested => $data->{refund_requested} || 0,
            refund_amount => $data->{refund_amount}
        };
    }
}