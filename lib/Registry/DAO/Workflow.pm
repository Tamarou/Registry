use v5.40.0;
use utf8;
use experimental qw(try);
use Object::Pad;

use Registry::DAO::Object;

class Registry::DAO::Workflow :isa(Registry::DAO::Object) {
    use YAML::XS;

    field $id :param :reader;
    field $slug :param :reader;
    field $name :param :reader;
    field $description :param :reader;

    field $first_step :param;

    use constant table => 'workflows';

    sub create ( $class, $db, $data ) {
        $db = $db->db if $db isa Registry::DAO;
        my %data =
          $db->insert( $class->table, $data, { returning => '*' } )->hash->%*;

        return $class->new(%data);
    }

    method first_step_slug ($db) {
        return $first_step;
    }

    method first_step ($db) {
        return unless $first_step;
        my $step = Registry::DAO::WorkflowStep->find( $db,
            { slug => $first_step, workflow_id => $id } );
            
        # If step not found but slug is defined, check if we need to create it
        if (!$step && $first_step) {
            # Log warning for debugging
            # TODO: Replace with proper logging
            # warn "First step '$first_step' not found for workflow $id (slug: $slug)";
        }
        
        return $step;
    }

    method get_step ( $db, $filter ) {
        Registry::DAO::WorkflowStep->find( $db,
            { workflow_id => $id, $filter->%* } );
    }

    method last_step ($db) {
        my $step = $self->first_step($db);
        return unless $step;

        while ( my $next = $step->next_step($db) ) {
            $step = $next;
        }
        return $step;
    }

    method add_step ( $db, $data ) {
        $data->{workflow_id} = $id;
        if ( my $last = $self->last_step($db) ) {
            $data->{depends_on} = $last->id;
        }
        
        my $step = Registry::DAO::WorkflowStep->create( $db, $data );
        unless ( $self->first_step($db) ) {
            $self->update( $db, { first_step => $step->slug }, { id => $id } );
            $first_step = $step->slug;
        }
        return $step;
    }

    method latest_run ( $db, $filter = {} ) {
        my ($run) = $self->runs( $db, $filter );
        return $run;
    }

    method new_run ( $db, $config //= {} ) {
        $config->{workflow_id} //= $id;
        Registry::DAO::WorkflowRun->create( $db, $config );
    }

    method runs ( $db, $filter = {} ) {
        my @runs = Registry::DAO::WorkflowRun->find( $db,
            { workflow_id => $id, $filter->%* } );
        return @runs;
    }

    method to_yaml($db) {

        # Build the basic workflow structure
        my $workflow = {
            name        => $name,
            description => $description,
            slug        => $slug,
        };
        
        # Always include first_step value from database
        $workflow->{first_step} = $first_step if $first_step;


        # Start with the first step and traverse
        my $current_step = $self->first_step($db);
        while ($current_step) {
            # Use the step's as_hash method and add directly to steps array
            $workflow->{steps} //= [];
            push $workflow->{steps}->@*, $current_step->as_hash($db);

            # Move to next step
            $current_step = $current_step->next_step($db);
        }

        # Return YAML string
        return Dump($workflow);
    }

    sub from_yaml ( $class, $db, $yaml ) {
        my $data = Load($yaml);
        die "Cannot load draft workflow" if $data->{draft};

        $data->{slug} //= lc( $data->{name} =~ s/\s+/-/gr );
        for my $field (qw(name description)) {
            die "Missing required field: $field"
              unless $data->{$field};
        }

        my $steps = delete $data->{steps};
        die "Missing required field: steps" unless $steps;

        if ( my $workflow =
            $db->find( 'Registry::DAO::Workflow', { slug => $data->{slug} } ) )
        {
            return $workflow;
        }

        my $txn = $db->begin;

        # Create new workflow
        my $workflow = $class->create( $db, $data );

        # Create subsequent steps
        for my $i ( 0 .. $#{$steps} ) {
            my $step = $steps->[$i];

            for my $field (qw(slug)) {
                die "Missing required field: $field" unless $step->{$field};
            }

            # Handle template if present
            if ( my $template_slug = delete $step->{template} ) {
                my $template = Registry::DAO::Template->find( $db,
                    { slug => $template_slug } );
                $step->{template_id} = $template->id if $template;
            }

            # Handle outcome definition references if present
            if (my $outcome_name = $step->{'outcome-definition'}) {
                # No regex extraction needed - just use the name directly
                my ($outcome_definition) = Registry::DAO::OutcomeDefinition->find(
                    $db, { name => $outcome_name }
                );
                
                if ($outcome_definition) {
                    $step->{outcome_definition_id} = $outcome_definition->id;
                }
                
                # Delete the key after processing
                delete $step->{'outcome-definition'};
            }

            # We've already processed outcome-definition, no need for backwards compatibility
            # code since our new method handles all cases

            # Add step to workflow
            my $new_step = $workflow->add_step( $db, $step );

        }
        $txn->commit;

        return $workflow;
    }
}

class Registry::DAO::WorkflowStep :isa(Registry::DAO::Object) {
    use Carp qw(confess);

    field $id :param :reader;
    field $slug :param :reader;
    field $workflow_id :param :reader;
    field $template_id :param :reader           = undef;
    field $outcome_definition_id :param :reader = undef;
    field $description :param :reader;

    field $depends_on :param = undef;

    # TODO: WorkflowStep class needs:
    # - Remove = {} default
    # - Add BUILD for JSON decoding
    # - Handle { -json => $metadata } in create/update
    # - Add explicit metadata() accessor
    field $metadata :param = {};
    field $class :param :reader;

    use constant table => 'workflow_steps';
    
    method outcome_definition($db) {
        return unless $outcome_definition_id;
        Registry::DAO::OutcomeDefinition->find($db, { id => $outcome_definition_id });
    }
    
    method get_schema_definition($db) {
        my $definition = $self->outcome_definition($db);
        return unless $definition;
        return $definition->schema;
    }
    
    method validate($db, $data) {
        my $definition = $self->outcome_definition($db);
        return { valid => 1 } unless $definition; # Skip validation if no definition
        
        # Get validation rules from outcome definition
        my $schema = $definition->schema;
        my @errors;
        
        # Basic field validation using JSON Schema
        for my $field ($schema->{fields}->@*) {
            my $field_id = $field->{id};
            # Check required fields
            if ($field->{required} && !defined $data->{$field_id}) {
                push @errors, {
                    field => $field_id,
                    message => "Field is required"
                };
                next;
            }
            
            # Additional validation for specific field types could be added here
        }
        
        return {
            valid => @errors ? 0 : 1,
            errors => \@errors
        };
    }
    
    # we store the subclass name in the database
    # so we need inflate the correct one
    sub find ( $class, $db, $filter, $order = { -desc => 'created_at' } ) {
        try {
            $db = $db->db if $db isa Registry::DAO;
            my $data =
              $db->select( $class->table, '*', $filter, $order )->expand->hash;
            return unless $data;
            return $data->{class}->new( $data->%* );
        }
        catch ($e) {
            confess $e;
        }
    }

    sub create ( $class, $db, $data ) {
        $data->{class} //= $class;
        $class->SUPER::create( $db, $data );
    }

    method next_step ($db) {
        Registry::DAO::WorkflowStep->find( $db, { depends_on => $id } );
    }

    method template ($db) {
        die "no template set for step $slug ($id)" unless $template_id;
        return Registry::DAO::Template->find( $db, { id => $template_id } );
    }

    method as_hash ($db) {
        # Create a base hash with only the fields that exist
        my $json = {};
        
        # Add basic fields if they exist
        $json->{slug} = $slug if $slug;
        $json->{description} = $description if $description;
        $json->{class} = $class if $class;
        
        # Get template information if it exists
        if ($template_id) {
            my $template_obj = $self->template($db);
            $json->{template} = $template_obj->slug if $template_obj;
        }
        
        # Get outcome definition information if it exists
        if ($outcome_definition_id) {
            my $outcome_obj = Registry::DAO::OutcomeDefinition->find($db, { id => $outcome_definition_id });
            if ($outcome_obj) {
                $json->{'outcome-definition'} = $outcome_obj->name;
            }
        }
        
        return $json;
    }

    method set_template ( $db, $template_id ) {
        $template_id = $template_id->id
          if $template_id isa Registry::DAO::Template;
        $db = $db->db if $db isa Registry::DAO;
        $db->update(
            $self->table,
            { template_id => $template_id },
            { id          => $id }
        );
    }

    method workflow ($db) {
        Registry::DAO::Workflow->find( $db, { id => $workflow_id } );
    }

    method process ( $db, $data ) { 
        # Always validate input
        my $validation = $self->validate($db, $data);
        if (!$validation->{valid}) {
            return { _validation_errors => $validation->{errors} };
        }
        
        # Default implementation - simple passthrough
        return $data;
    }
}

class Registry::DAO::WorkflowRun :isa(Registry::DAO::Object) {
    use Mojo::JSON qw(encode_json);
    use Carp       qw( croak );

    field $id :param      = 0;
    field $user_id :param = 0;
    field $workflow_id :param;
    field $latest_step_id :param  = undef;
    field $continuation_id :param = undef;

    # This is our reference implementation for JSONB handling
    field $data :param //= {};
    field $created_at :param;

    use constant table => 'workflow_runs';

    method id()   { $id }
    method data() { $data }

    method workflow ($db) {
        Registry::DAO::Workflow->find( $db, { id => $workflow_id } );
    }

    method completed ($db) {
        my ($workflow) = $self->workflow($db);
        $self->latest_step($db)->slug eq $workflow->last_step($db)->slug;
    }

    method latest_step ($db) {
        Registry::DAO::WorkflowStep->find( $db, { id => $latest_step_id } );
    }

    method update_data ( $db, $new_data ||= {} ) {
        croak "new data must be a hashref" unless ref $new_data eq 'HASH';
        $data = $db->update(
            $self->table,
            { data      => encode_json( { $data->%*, $new_data->%* } ) },
            { id        => $id },
            { returning => ['data'] }
        )->expand->hash->{data};
    }

    method process ( $db, $step, $new_data = {} ) {
        unless ( $step isa Registry::DAO::WorkflowStep ) {
            $step = Registry::DAO::WorkflowStep->find( $db, $step );
        }

        # TODO we really should inline these two calls into a single query
        $self->update_data( $db, $step->process( $db, $new_data ) );
        ($latest_step_id) = $db->update(
            $self->table,
            { latest_step_id => $step->id },
            { id             => $id },
            { returning      => [qw(latest_step_id)] }
        )->expand->hash->@{qw(latest_step_id)};

        return $data;
    }

    method first_step ($db) {
        return $self->workflow($db)->first_step($db) unless $latest_step_id;
        Registry::DAO::WorkflowStep->find(
            $db,
            {
                workflow_id => $workflow_id,
                depends_on  => $latest_step_id,
            }
        ) // $self->workflow($db)->first_step($db);
    }

    method next_step ($db) {
        return $self->first_step($db) unless $latest_step_id;
        Registry::DAO::WorkflowStep->find(
            $db,
            {
                workflow_id => $workflow_id,
                depends_on  => $latest_step_id,
            }
        );
    }

    method has_continuation { defined $continuation_id }

    method continuation ($db) {
        return unless $continuation_id;
        Registry::DAO::WorkflowRun->find( $db, { id => $continuation_id } );
    }
}
