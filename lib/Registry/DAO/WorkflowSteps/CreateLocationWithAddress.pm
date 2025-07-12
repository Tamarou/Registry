use 5.40.2;
use utf8;
use Object::Pad;

use Registry::DAO::Workflow;
use Mojo::JSON;

class Registry::DAO::WorkflowSteps::CreateLocationWithAddress :isa(Registry::DAO::WorkflowStep) {

    method process ( $db, $form_data ) {
        my ($workflow) = $self->workflow($db);
        my $run        = $workflow->latest_run($db);
        
        # Get basic location data
        my %data = (
            name => $form_data->{name} || $run->data->{name}, 
            metadata => $run->data->{metadata} || {}
        );
        
        # Extract address info from form data
        my $address_info = {};
        
        # Process address fields from form
        foreach my $key (keys %$form_data) {
            if ($key =~ /^address_info\.(.+)$/) {
                $address_info->{$1} = $form_data->{$key};
            }
        }
        
        # If we have address info, add it to the location metadata
        if (keys %$address_info) {
            $data{address_info} = $address_info;
        }
        
        # Create the location
        # TODO: Replace with proper logging
        # warn "Creating location with data: " . Mojo::JSON::encode_json(\%data);
        my $location = Registry::DAO::Location->create( $db, \%data );
        
        # Update the run data
        $run->update_data( $db, { 
            location => $location->id,
            locations => [ $location->id ]
        });
        
        # Handle continuation if present
        if ( $run->has_continuation ) {
            my ($continuation) = $run->continuation($db);
            my $locations = $continuation->data->{locations} // [];
            push $locations->@*, $location->id;
            $continuation->update_data( $db, { locations => $locations } );
        }
        
        return { location => $location->id };
    }
}