use 5.40.2;
use Object::Pad;

class Registry::DAO::Workflow :isa(Registry::DAO::Object) {
    use YAML::XS;

    field $id :param :reader;
    field $slug :param :reader;
    field $name :param :reader;
    field $description :param :reader;

    field $first_step :param;

    sub table { 'workflows' }

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