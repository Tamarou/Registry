# ABOUTME: Completes drop request processing by updating request status
# ABOUTME: Marks drop request as approved/denied and records admin processing details
use 5.40.2;
use utf8;
use Object::Pad;

class Registry::DAO::WorkflowSteps::CompleteDropRequest :isa(Registry::DAO::WorkflowStep) {
    use Carp qw(confess);
    use Scalar::Util qw(blessed);

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my ($run)      = $workflow->latest_run($db);
        my $data       = $run->data;

        my $drop_request_id = $data->{drop_request_id}
            or confess "drop_request_id is required for completing drop request";

        my $drop_request = Registry::DAO::DropRequest->find($db, { id => $drop_request_id })
            or confess "Drop request $drop_request_id not found";

        # Extract admin user info
        my $admin_user = $data->{admin_user};
        my $admin_id = blessed($admin_user) ? $admin_user->id : $admin_user->{id};

        # Update drop request status
        $drop_request->update($db, {
            status => 'approved',
            admin_notes => $data->{admin_notes} || '',
            processed_by => $admin_id,
            processed_at => \'now()'
        });

        return {
            drop_request_completed => 1,
            status => 'approved',
            processed_by => $admin_id
        };
    }
}