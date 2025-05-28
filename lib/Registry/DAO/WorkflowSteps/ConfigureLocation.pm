package Registry::DAO::WorkflowSteps::ConfigureLocation;
use 5.40.2;
use warnings;
use experimental 'signatures', 'try', 'builtin';

use Object::Pad;
class Registry::DAO::WorkflowSteps::ConfigureLocation :isa(Registry::DAO::WorkflowStep);

use Registry::DAO::ProgramType;

method process ($db, $form_data) {
    my $workflow = $self->workflow($db);
    my $run = $workflow->latest_run($db);
    my $data = $run->data;
    
    # If form was submitted
    if ($form_data->{location_configs}) {
        my $location_configs = $form_data->{location_configs};
        
        # Validate and process location configurations
        my @configured_locations;
        for my $location (@{$data->{selected_locations}}) {
            my $location_id = $location->{id};
            my $config = $location_configs->{$location_id};
            
            # Validate required fields
            unless ($config->{capacity} && $config->{capacity} > 0) {
                return {
                    next_step => $self->id,
                    errors => ["Capacity must be greater than 0 for location: $location->{name}"],
                    data => $self->prepare_data($db)
                };
            }
            
            # Apply program type defaults if not overridden
            my $program_type_config = $data->{project_metadata}->{program_type_config} || {};
            my $standard_times = $program_type_config->{standard_times} || {};
            
            push @configured_locations, {
                %$location,
                capacity => int($config->{capacity}),
                schedule => $config->{schedule} || $standard_times,
                pricing_override => $config->{pricing_override},
                notes => $config->{notes} || ''
            };
        }
        
        # Store configurations in workflow data
        $run->data->{configured_locations} = \@configured_locations;
        $run->save($db);
        
        return { next_step => 'generate-events' };
    }
    
    # Show configuration form
    return {
        next_step => $self->id,
        data => $self->prepare_data($db)
    };
}

method prepare_data ($db) {
    my $workflow = $self->workflow($db);
    my $run = $workflow->latest_run($db);
    my $data = $run->data;
    
    # Get program type defaults
    my $program_type_config = $data->{project_metadata}->{program_type_config} || {};
    my $standard_times = $program_type_config->{standard_times} || {};
    
    return {
        project_name => $data->{project_name},
        selected_locations => $data->{selected_locations},
        program_type_config => $program_type_config,
        standard_times => $standard_times
    };
}

method template { 'program-location-assignment/configure-location' }

1;