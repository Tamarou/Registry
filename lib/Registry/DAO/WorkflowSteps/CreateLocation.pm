use 5.40.2;
use utf8;
use Object::Pad;

use Registry::DAO::Workflow;

class Registry::DAO::WorkflowSteps::CreateLocation :isa(Registry::DAO::WorkflowStep) {

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my $run        = $workflow->latest_run($db);
        my %data       = $run->data->%{ 'name', 'metadata', 'notes' };
        my $location   = Registry::DAO::Location->create( $db, \%data );
        $run->update_data( $db, { locations => [ $location->id ] } );

        if ( $run->has_continuation ) {
            my ($continuation) = $run->continuation($db);
            my $locations = $continuation->data->{locations} // [];
            push $locations->@*, $location->id;
            $continuation->update_data( $db, { locations => $locations } );
        }
        return { location => $location->id };
    }
}