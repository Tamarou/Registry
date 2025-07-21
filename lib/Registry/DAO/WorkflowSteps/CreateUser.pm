use 5.40.2;
use utf8;
use Object::Pad;

use Registry::DAO::Workflow;

class Registry::DAO::WorkflowSteps::CreateUser :isa(Registry::DAO::WorkflowStep) {

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my ($run)      = $workflow->latest_run($db);

        my $data = $run->data;

        
        my $user = Registry::DAO::User->create( $db,
            { $data->%{ 'username', 'password' } } );

        $run->update_data(
            $db,
            {
                password => '',
                passhash => $user->passhash,
                id       => $user->id,
            }
        );

        if ( $run->has_continuation ) {
            my ($continuation) = $run->continuation($db);
            my $users = $continuation->data->{users} // [];
            push $users->@*, { id => $user->id };
            $continuation->update_data( $db, { users => $users } );
        }

        return { user => $user->id };
    }
}