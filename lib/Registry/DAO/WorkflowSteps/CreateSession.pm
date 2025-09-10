use 5.40.2;
use utf8;
use Object::Pad;

use Registry::DAO::Workflow;

class Registry::DAO::WorkflowSteps::CreateSession :isa(Registry::DAO::WorkflowStep) {

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my ($run)      = $workflow->latest_run($db);

        my $data   = $run->data;
        
        # Extract session creation data
        my %session_data = $data->%{ 'name', 'metadata', 'notes' };
        
        # Handle time data if provided (convert to date fields)
        if ($data->{time}) {
            # Store time in metadata if it's not a standard session field
            $session_data{metadata} //= {};
            $session_data{metadata}{time} = $data->{time};
        }

        my $session = Registry::DAO::Session->create( $db, \%session_data );
        
        # Add events if provided
        my $events = $data->{events};
        if ($events) {
            # Mojolicious unwinds form posts of only one value
            $events = [$events] unless ref $events eq 'ARRAY';
            $session->add_events( $db, $events->@* );
        }
        
        # Add teacher if provided
        if ($data->{teacher_id}) {
            $session->add_teachers( $db, $data->{teacher_id} );
        }

        if ( $run->has_continuation ) {
            my ($continuation) = $run->continuation($db);
            my $sessions = $continuation->data->{sessions} // [];
            push $sessions->@*, $session->id;
            $continuation->update_data( $db, { sessions => $sessions } );
        }

        return { session => $session->id };
    }
}