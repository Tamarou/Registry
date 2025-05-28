package Registry::DAO::WorkflowSteps::ChooseLocations;
use 5.40.2;
use warnings;
use experimental 'signatures', 'try', 'builtin';

use Object::Pad;
class Registry::DAO::WorkflowSteps::ChooseLocations :isa(Registry::DAO::WorkflowStep);

use Registry::DAO::Location;

method process ($db, $form_data) {
    my $workflow = $self->workflow($db);
    my $run = $workflow->latest_run($db);
    
    # If form was submitted
    if ($form_data->{location_ids} && ref $form_data->{location_ids} eq 'ARRAY') {
        my @location_ids = @{$form_data->{location_ids}};
        
        # Validate all locations exist
        my @locations;
        for my $location_id (@location_ids) {
            my $location = Registry::DAO::Location->new(
                id => $location_id
            )->load($db);
            
            unless ($location) {
                return {
                    next_step => $self->id,
                    errors => ["Invalid location selected: $location_id"],
                    data => $self->prepare_data($db)
                };
            }
            push @locations, {
                id => $location->id,
                name => $location->name,
                address => $location->address,
                capacity => $location->capacity
            };
        }
        
        # Store selections in workflow data
        $run->data->{selected_locations} = \@locations;
        $run->save($db);
        
        return { next_step => 'configure-location' };
    }
    
    # Show selection form
    return {
        next_step => $self->id,
        data => $self->prepare_data($db)
    };
}

method prepare_data ($db) {
    # Get all available locations
    my $locations = Registry::DAO::Location->list($db);
    
    return {
        locations => $locations,
        project_name => $self->workflow($db)->latest_run($db)->data->{project_name}
    };
}

method template { 'program-location-assignment/choose-locations' }

1;