use 5.40.2;
use Object::Pad;

class Registry::Controller::Workflows :isa(Mojolicious::Controller) {
    use Carp qw(confess);

    method workflow ( $slug = $self->param('workflow') ) {
        my $dao = $self->app->dao;
        return $dao->find( Workflow => { slug => $slug } );
    }

    method run ( $id = $self->param('run') ) {
        my $dao = $self->app->dao;
        ( $dao->find( WorkflowRun => { id => $id } ) )[0];
    }

    method new_run ( $workflow, $config //= {} ) {
        my $dao = $self->app->dao;
        confess "Missing workflow parameter" unless $workflow;
        
        # Make sure the workflow has all necessary steps before creating a run
        my $first_step_slug = $workflow->first_step_slug($dao->db) || 'landing';
        my $first_step = $workflow->first_step($dao->db);
        
        # If first step doesn't exist, create it automatically (important for YAML-defined workflows)
        if (!$first_step) {
            warn "Creating missing first step '$first_step_slug' for workflow ${\ $workflow->slug}";
            $first_step = Registry::DAO::WorkflowStep->create(
                $dao->db,
                {
                    workflow_id => $workflow->id,
                    slug => $first_step_slug,
                    description => "Auto-created first step",
                    class => 'Registry::DAO::WorkflowStep'
                }
            );
            
            # Update workflow's first_step if it wasn't set
            unless ($workflow->first_step_slug($dao->db)) {
                $dao->db->update(
                    'workflows',
                    { first_step => $first_step_slug },
                    { id => $workflow->id }
                );
            }
        }
        
        my $run = $workflow->new_run( $dao->db, $config );
        my $data = $self->req->params->to_hash;
        $run->process( $dao->db, $first_step, $data );
        return $run;
    }

    method index() {
        my $dao      = $self->app->dao;
        my $workflow = $self->workflow();

        $self->render(
            template => $self->param('workflow') . '/index',
            action   => $self->url_for('workflow_start')
        );
    }

    method start_workflow() {
        my $dao       = $self->app->dao;
        my $workflow = $self->workflow();
        
        # Now try to start the run with auto-repair in the new_run method
        my $run;
        
        # Catch any DB errors during run creation/step processing
        eval {
            $run = $self->new_run($workflow);
        };
        if ($@) {
            # TODO: Replace with proper logging
            # warn "Error during new_run: $@";
            
            # Manual repair approach if normal workflow fails
            my $first_step_slug = $workflow->first_step_slug($dao->db) || 'landing';
            
            # Direct DB check if the step exists (bypassing object layer)
            my $exists = $dao->db->select(
                'workflow_steps', 
                'id', 
                { workflow_id => $workflow->id, slug => $first_step_slug }
            )->rows;
            
            # Step exists in DB but lookup failed - force create the run
            my $step_id;
            if ($exists) {
                # Get the step ID directly
                $step_id = $dao->db->select(
                    'workflow_steps',
                    'id',
                    { workflow_id => $workflow->id, slug => $first_step_slug }
                )->hash->{id};
                
                # TODO: Replace with proper logging
                # warn "Found existing step '$first_step_slug' with ID $step_id using direct DB query";
            }
            else {
                # Step genuinely doesn't exist - create it with trapping
                eval {
                    my $step = Registry::DAO::WorkflowStep->create(
                        $dao->db,
                        {
                            workflow_id => $workflow->id,
                            slug => $first_step_slug,
                            description => "Emergency auto-created step",
                            class => 'Registry::DAO::WorkflowStep'
                        }
                    );
                    $step_id = $step->id;
                };
                if ($@) {
                    # If creation failed, try one more direct lookup
                    # TODO: Replace with proper logging
                    # warn "Step creation failed: $@";
                    $step_id = $dao->db->select(
                        'workflow_steps',
                        'id',
                        { workflow_id => $workflow->id, slug => $first_step_slug }
                    )->hash->{id};
                    
                    # If still can't find it, we have to fail
                    unless ($step_id) {
                        die "Cannot find or create workflow step '$first_step_slug'";
                    }
                }
            }
            
            # Create the run manually with the step ID we found/created
            $run = $workflow->new_run($dao->db);
            
            # Process the run with the step ID directly
            my $data = $self->req->params->to_hash;
            $dao->db->update(
                'workflow_runs',
                { latest_step_id => $step_id },
                { id => $run->id }
            );
        }
        
        # Get the next step
        my $next_step = $run->next_step($dao->db);
        unless ($next_step) {
            # If there's no next step but we have a step, we might be at the end already
            if ($run->latest_step($dao->db)) {
                $self->render(text => 'DONE', status => 201);
                return;
            }
            
            die "Workflow (${\ $workflow->slug}) unable to process";
        }
        
        $self->redirect_to(
            $self->url_for(
                'workflow_step',
                run  => $run->id,
                step => $next_step->slug,
            )
        );
    }

    method get_workflow_run_step {
        my $dao = $self->app->dao;
        my $run = $self->run();
        my $step = $run->latest_step($dao->db) || $run->next_step($dao->db);
        
        # Get data for rendering
        my $data_json = Mojo::JSON::encode_json($run->data || {});
        my $errors_json = Mojo::JSON::encode_json($self->flash('validation_errors') || []);
        
        return $self->render(
            template => $self->param('workflow') . '/' . $self->param('step'),
            workflow => $self->param('workflow'),
            step     => $self->param('step'),
            status   => 200,
            action   => $self->url_for('workflow_process_step'),
            outcome_definition_id => $step->outcome_definition_id,
            data_json => $data_json,
            errors_json => $errors_json,
        );
    }

    method process_workflow_run_step {
        my $dao = $self->app->dao;

        my ($run) = $dao->find(
            WorkflowRun => {
                id => $self->param('run'),
            }
        );

        # if we're done, stop now
        if ( $run->completed( $dao->db ) ) {
            return $self->render( text => 'DONE', status => 201 );
        }

        # we're not done so process the next step
        my ($step) = $run->next_step( $dao->db );
        die "No step found" unless $step;

        die "Wrong step expected ${\$step->slug}"
          unless $step->slug eq $self->param('step');

        my $data = $self->req->params->to_hash;

        my $result = $run->process( $dao->db, $step, $data );
        
        # Check for validation errors
        if ($result->{_validation_errors}) {
            # Store errors in flash for retrieval on redirect
            $self->flash(validation_errors => $result->{_validation_errors});
            
            return $self->redirect_to($self->url_for);
        }

        # if we're still not done, redirect to the next step
        if ( !$run->completed( $dao->db ) ) {
            my ($next) = $run->next_step( $dao->db );
            my $url = $self->url_for( step => $next->slug );
            return $self->redirect_to($url);
        }

        # if this is a continuation, redirect to the continuation
        if ( $run->has_continuation ) {
            my ($run)      = $run->continuation( $dao->db );
            my ($workflow) = $run->workflow( $dao->db );
            my ($step)     = $run->next_step( $dao->db );
            my $url        = $self->url_for(
                'workflow_step',
                workflow => $workflow->slug,
                run      => $run->id,
                step     => $step->slug,
            );
            return $self->redirect_to($url);
        }

        return $self->render( text => 'DONE', status => 201 );
    }

    method get_outcome_definition {
        my $id = $self->param('id');
        my $dao = $self->app->dao;
        
        my $definition = Registry::DAO::OutcomeDefinition->find($dao->db, { id => $id });
        
        if (!$definition) {
            return $self->render(json => { error => 'Outcome definition not found' }, status => 404);
        }
        
        return $self->render(json => $definition->schema);
    }
    
    method validate_outcome {
        my $dao = $self->app->dao;
        my $json = $self->req->json;
        
        my $outcome_id = $json->{outcome_definition_id};
        my $data = $json->{data};
        
        my $step = Registry::DAO::WorkflowStep->new(outcome_definition_id => $outcome_id);
        my $validation = $step->validate($dao->db, $data);
        
        return $self->render(json => $validation);
    }

    method start_continuation {
        my $dao      = $self->app->dao;
        my $workflow = $dao->find(
            Workflow => {
                slug => $self->param('target')
            }
        );

        my $run = $self->new_run( $workflow,
            { continuation_id => $self->param('run') } );

        $self->redirect_to(
            $self->url_for(
                'workflow_step',
                workflow => $self->param('target'),
                run      => $run->id,
                step     => $run->next_step( $dao->db )->slug,
            )
        );
    }
}
