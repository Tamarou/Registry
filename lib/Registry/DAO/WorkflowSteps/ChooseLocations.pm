use 5.42.0;

use Object::Pad;

class Registry::DAO::WorkflowSteps::ChooseLocations :isa(Registry::DAO::WorkflowStep) {

use Registry::DAO::Location;

method process ($db, $form_data, $run = undef) {
    $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };
    
    # If form was submitted. A single checked checkbox arrives as a scalar
    # from Mojo's param->to_hash; multiple arrive as an arrayref. Normalize.
    if ($form_data->{location_ids}) {
        my $ids = $form_data->{location_ids};
        my @location_ids = ref $ids eq 'ARRAY' ? @$ids : ($ids);
        
        # Validate all locations exist
        my @locations;
        for my $location_id (@location_ids) {
            my $location = Registry::DAO::Location->find($db, {
                id => $location_id
            });

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

# Render contract: templates read stash('step_data'), so wrap prepare_data
# under that key for the controller's GET render path.
method prepare_template_data ($db, $run, $params = {}) {
    return { step_data => $self->prepare_data($db) };
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

}