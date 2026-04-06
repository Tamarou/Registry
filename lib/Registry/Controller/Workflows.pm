use 5.42.0;
use utf8;
use Object::Pad;

class Registry::Controller::Workflows :isa(Registry::Controller) {
    use Carp qw(confess);
    use DateTime;

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
        
        # Add tenant context to workflow run data if present
        my $tenant_slug = $self->tenant;
        if ($tenant_slug && $tenant_slug ne 'registry') {
            $data->{__tenant_slug} = $tenant_slug;
        }
        
        $run->process( $dao->db, $first_step, $data );
        return $run;
    }

    method index() {
        my $dao = $self->app->dao;
        my $workflow = $self->workflow();
        my $workflow_slug = $self->param('workflow');

        # Backwards compatibility: if a {workflow}/index template exists,
        # use the old rendering path (no auto-run).
        my $index_template = $workflow_slug . '/index';
        if ($self->app->renderer->template_path({ template => $index_template, format => 'html', handler => 'ep' })) {
            return $self->render(
                template => $index_template,
                action   => $self->url_for('workflow_start'),
            );
        }

        # Auto-run path: find or create a run and render the first step
        # directly with a live run ID, enabling callcc buttons and filter
        # forms without a separate POST step.
        my $run = $self->_find_or_create_run($workflow);
        my $step = $run->latest_step($dao->db) || $workflow->first_step($dao->db);

        return unless $step;

        my $data_json = Mojo::JSON::encode_json($run->data || {});
        my $errors_json = Mojo::JSON::encode_json($self->flash('validation_errors') || []);
        my $template_data = $step->prepare_template_data($dao->db, $run);
        my $workflow_progress = $self->_get_workflow_progress($run, $step);

        $self->render(
            template => $workflow_slug . '/' . $step->slug,
            workflow => $workflow_slug,
            step     => $step->slug,
            status   => 200,
            action   => $self->url_for('workflow_process_step',
                workflow => $workflow_slug,
                run      => $run->id,
                step     => $step->slug),
            run      => $run,
            data_json => $data_json,
            errors_json => $errors_json,
            workflow_progress => $workflow_progress,
            %$template_data,
        );
    }

    method _find_or_create_run ($workflow) {
        my $dao = $self->app->dao;
        my $session_key = "workflow_run_${\$workflow->slug}";

        # Check session for an existing run ID
        my $run_id = $self->session->{$session_key};
        if ($run_id) {
            my ($run) = $dao->find(WorkflowRun => { id => $run_id });
            if ($run && !$run->completed($dao->db)) {
                return $run;
            }
        }

        # Create a new run and store in session
        my $run = $self->new_run($workflow);
        $self->session->{$session_key} = $run->id;
        return $run;
    }

    method start_workflow() {
        my $dao = $self->app->dao;
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
        my $workflow = $self->workflow();
        
        # Find the step that matches the URL parameter, not just the latest step
        my $requested_step_slug = $self->param('step');
        my $step = Registry::DAO::WorkflowStep->find($dao->db, { 
            workflow_id => $workflow->id, 
            slug => $requested_step_slug 
        });
        
        # Fallback to latest step if the requested step isn't found
        $step ||= $run->latest_step($dao->db) || $run->next_step($dao->db);
        
        # Get data for rendering
        my $data_json = Mojo::JSON::encode_json($run->data || {});
        my $errors_json = Mojo::JSON::encode_json($self->flash('validation_errors') || []);
        
        # Get workflow progress data
        my $workflow_progress = $self->_get_workflow_progress($run, $step);
        
        # Let the step class handle its own template data preparation (polymorphic approach)
        my $template_data = $step->prepare_template_data($dao->db, $run);
        
        return $self->render(
            template => $self->param('workflow') . '/' . $self->param('step'),
            workflow => $self->param('workflow'),
            step     => $self->param('step'),
            status   => 200,
            action   => $self->url_for('workflow_process_step',
                workflow => $self->param('workflow'),
                run => $self->param('run'),
                step => $self->param('step')),
            outcome_definition_id => $step->outcome_definition_id,
            data_json => $data_json,
            errors_json => $errors_json,
            workflow_progress => $workflow_progress,
            %$template_data,
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
        
        # Special validation for review step
        if ($step->slug eq 'review') {
            unless ($data->{terms_accepted}) {
                $self->flash(validation_errors => ['Terms of Service must be accepted to continue']);
                return $self->redirect_to($self->url_for);
            }
            
            # Validate that required data exists
            my $run_data = $run->data || {};
            my @missing_fields;
            
            # Check organization info
            push @missing_fields, 'Organization name' unless $run_data->{name} || $run_data->{organization_name};
            push @missing_fields, 'Contact email' unless $run_data->{billing_email} || $run_data->{admin_email};
            push @missing_fields, 'Admin name' unless $run_data->{admin_name};
            push @missing_fields, 'Admin email' unless $run_data->{admin_email};
            
            if (@missing_fields) {
                $self->flash(validation_errors => [
                    'Missing required information: ' . join(', ', @missing_fields)
                ]);
                return $self->redirect_to($self->url_for);
            }
        }

        my $result = $run->process( $dao->db, $step, $data );

        # Check for validation errors from workflow steps.
        # Steps may use either '_validation_errors' or 'errors' key.
        my $validation_errors = $result->{_validation_errors} || $result->{errors};
        if ($validation_errors) {
            if ($self->is_htmx_request) {
                # HTMX: re-render current step as fragment with errors
                $self->stash(_htmx_fragment => 1);
                my $workflow_slug = $self->param('workflow');
                my $step_slug    = $self->param('step');
                my $template_data = $step->prepare_template_data($dao->db, $run);
                return $self->render(
                    template    => $workflow_slug . '/' . $step_slug,
                    errors_json => Mojo::JSON::encode_json($validation_errors),
                    action      => $self->url_for('workflow_process_step',
                        workflow => $workflow_slug,
                        run      => $self->param('run'),
                        step     => $step_slug),
                    run         => $run,
                    %$template_data,
                );
            }

            # No JS: store errors in flash for retrieval on redirect
            $self->flash(validation_errors => $validation_errors);
            return $self->redirect_to($self->url_for);
        }

        # Check for stay -- step wants to remain on the current page.
        # Render directly instead of redirecting so template_data from
        # the step result reaches the template (redirect loses POST context).
        if ($result->{stay}) {
            my $template_data = $result->{template_data} || {};
            my $workflow_slug = $self->param('workflow');
            my $step_slug = $self->param('step');

            my $data_json = Mojo::JSON::encode_json($run->data || {});
            my $errors_json = Mojo::JSON::encode_json(
                $result->{errors} || $self->flash('validation_errors') || []
            );
            my $workflow_progress = $self->_get_workflow_progress($run, $step);

            # HTMX: render fragment (no layout), no URL push for stay
            if ($self->is_htmx_request) {
                $self->stash(_htmx_fragment => 1);
            }

            return $self->render(
                template          => $workflow_slug . '/' . $step_slug,
                workflow          => $workflow_slug,
                step              => $step_slug,
                status            => 200,
                action            => $self->url_for('workflow_process_step',
                    workflow => $workflow_slug,
                    run      => $self->param('run'),
                    step     => $step_slug),
                run               => $run,
                data_json         => $data_json,
                errors_json       => $errors_json,
                workflow_progress => $workflow_progress,
                %$template_data,
            );
        }

        # if we're still not done, redirect to the next step
        if ( !$run->completed( $dao->db ) ) {
            my ($next) = $run->next_step( $dao->db );
            my $next_url = $self->url_for( step => $next->slug );

            if ($self->is_htmx_request) {
                # HTMX: render next step as fragment, push URL
                $self->stash(_htmx_fragment => 1);
                $self->htmx->res->push_url($next_url);
                my $workflow_slug = $self->param('workflow');
                my $template_data = $next->prepare_template_data($dao->db, $run);
                return $self->render(
                    template => $workflow_slug . '/' . $next->slug,
                    workflow => $workflow_slug,
                    step     => $next->slug,
                    action   => $self->url_for('workflow_process_step',
                        workflow => $workflow_slug,
                        run      => $self->param('run'),
                        step     => $next->slug),
                    run      => $run,
                    %$template_data,
                );
            }

            # No JS: traditional redirect
            return $self->redirect_to($next_url);
        }

        # if this is a continuation, redirect to the continuation
        if ( $run->has_continuation ) {
            my ($parent_run)  = $run->continuation( $dao->db );
            my ($workflow)    = $parent_run->workflow( $dao->db );
            # Use next_step if parent has one, otherwise re-render latest step
            # (handles single-step parent workflows like the tenant storefront)
            my ($step)        = $parent_run->next_step( $dao->db )
                             || $parent_run->latest_step( $dao->db );
            my $url           = $self->url_for(
                'workflow_step',
                workflow => $workflow->slug,
                run      => $parent_run->id,
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
    
    method validate_subdomain {
        my $dao = $self->app->dao;
        my $name = $self->param('name');
        
        unless ($name) {
            return $self->render(
                inline => '<span class="subdomain-slug">organization</span>.tinyartempire.com',
                format => 'html'
            );
        }
        
        # Generate slug using same logic as RegisterTenant
        my $slug = $self->_generate_subdomain_slug($dao->db, $name);
        my $is_available = !$self->_slug_exists($dao->db, $slug);
        
        my $status_class = $is_available ? 'available' : 'unavailable';
        my $status_text = $is_available ? 'Available' : 'Already taken';
        
        my $icon = $is_available ? 'OK' : 'X';
        return $self->render(
            inline => '<span class="subdomain-slug <%= $status_class %>"><%= $slug %></span>.tinyartempire.com'
                     . '<div class="subdomain-status <%= $status_class %>">'
                     . '<span class="status-icon"><%= $icon %></span>'
                     . '<%= $status_text %>'
                     . '</div>',
            format => 'html',
            slug => $slug,
            status_class => $status_class,
            status_text => $status_text,
            icon => $icon,
        );
    }

    method _get_workflow_progress($run, $current_step) {
        my $dao = $self->app->dao;
        my $workflow = $run->workflow($dao->db);
        
        # Get all workflow steps in order
        my $steps = $workflow->get_ordered_steps($dao->db);
        
        return {} unless @$steps;
        
        # Find current step position
        my $current_position = 1;
        my $current_step_id = $current_step ? $current_step->id : undef;
        
        for my $i (0 .. $#$steps) {
            if ($steps->[$i]{id} eq $current_step_id) {
                $current_position = $i + 1;
                last;
            }
        }
        
        # Generate step names and URLs
        my @step_names;
        my @step_urls;
        my @completed_steps;
        
        for my $i (0 .. $#$steps) {
            my $step = $steps->[$i];
            my $step_number = $i + 1;
            
            # Use description if available, otherwise generate from slug
            my $step_name = $step->{description};
            if (!$step_name || $step_name eq 'Auto-created first step' || $step_name eq 'Emergency auto-created step') {
                $step_name = $self->_generate_step_name($step->{slug});
            }
            push @step_names, $step_name;
            
            # Generate URL for navigation (only for completed steps)
            my $step_url = '';
            if ($step_number < $current_position) {
                $step_url = $self->url_for(
                    'workflow_step',
                    workflow => $workflow->slug,
                    run => $run->id,
                    step => $step->{slug}
                );
                push @completed_steps, $step_number;
            } elsif ($step_number == $current_position) {
                # Current step - no URL needed but mark as accessible
                $step_url = '';
            } else {
                # Future step - no URL
                $step_url = '';
            }
            push @step_urls, $step_url;
        }
        
        return {
            current_step => $current_position,
            total_steps => scalar(@$steps),
            step_names => join(',', @step_names),
            step_urls => join(',', @step_urls),
            completed_steps => join(',', @completed_steps),
        };
    }
    
    method _generate_step_name($slug) {
        # Convert slug to human-readable name
        my $name = $slug;
        $name =~ s/-/ /g;
        $name =~ s/\b(\w)/\u$1/g;  # Title case
        return $name;
    }
    
    method _generate_subdomain_slug($db, $name) {
        # Generate slug: lowercase, replace spaces/special chars with hyphens, remove multiple hyphens
        my $slug = lc($name);
        # For validation, use a simple approach without Text::Unidecode dependency
        $slug =~ s/[^a-z0-9\s-]//g;  # Remove special characters
        $slug =~ s/\s+/-/g;  # Replace spaces with hyphens
        $slug =~ s/-+/-/g;   # Remove multiple consecutive hyphens
        $slug =~ s/^-|-$//g; # Remove leading/trailing hyphens
        $slug = substr($slug, 0, 50);  # Limit length
        $slug = 'organization' if !$slug;  # Fallback if empty
        
        # Ensure uniqueness by checking existing tenants
        my $original_slug = $slug;
        my $counter = 1;
        
        while (Registry::DAO::Tenant->slug_exists($db, $slug)) {
            $slug = "${original_slug}-${counter}";
            $counter++;
            last if $counter > 999;  # Prevent infinite loop
        }
        
        return $slug;
    }
    
    method _slug_exists($db, $slug) {
        my $result = $db->query('SELECT COUNT(*) FROM registry.tenants WHERE slug = ?', $slug);
        return $result->array->[0] > 0;
    }
    
    

    method start_continuation {
        my $dao = $self->app->dao;
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
