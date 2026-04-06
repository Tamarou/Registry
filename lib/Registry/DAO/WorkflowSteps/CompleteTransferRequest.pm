# ABOUTME: Completes transfer request processing by updating request status
# ABOUTME: Marks transfer request as approved/denied and records admin processing details
use 5.42.0;
use utf8;
use Object::Pad;

class Registry::DAO::WorkflowSteps::CompleteTransferRequest :isa(Registry::DAO::WorkflowStep) {
    use Carp qw(confess);
    use Scalar::Util qw(blessed);

    method process ( $db, $, $run = undef ) {
        $run //= do { my ($w) = $self->workflow($db); $w->latest_run($db) };
        my $data       = $run->data;

        my $transfer_request_id = $data->{transfer_request_id}
            or confess "transfer_request_id is required for completing transfer request";

        my $transfer_request = Registry::DAO::TransferRequest->find($db, { id => $transfer_request_id })
            or confess "Transfer request $transfer_request_id not found";

        # Extract admin user info
        my $admin_user = $data->{admin_user};
        my $admin_id = blessed($admin_user) ? $admin_user->id : $admin_user->{id};

        # Update transfer request status
        $transfer_request->update($db, {
            status => 'approved',
            admin_notes => $data->{admin_notes} || '',
            processed_by => $admin_id,
            processed_at => \'now()'
        });

        return {
            transfer_request_completed => 1,
            status => 'approved',
            processed_by => $admin_id
        };
    }
}