use v5.40.0;
use utf8;
use Object::Pad;

use Registry::DAO::Workflow;

class Registry::DAO::CreateProject :isa(Registry::DAO::WorkflowStep) {

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my $run        = $workflow->latest_run($db);
        my %data       = $run->data->%{ 'name', 'metadata', 'notes' };
        my $project    = Registry::DAO::Project->create( $db, \%data );
        $run->update_data( $db, { projects => [ $project->id ] } );
        if ( $run->has_continuation ) {
            my ($continuation) = $run->continuation($db);
            my $projects = $continuation->data->{projects} // [];
            push $projects->@*, $project->id;
            $continuation->update_data( $db, { projects => $projects } );
        }
        return { project => $project->id };
    }
}

class Registry::DAO::CreateLocation :isa(Registry::DAO::WorkflowStep) {

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

class Registry::DAO::RegisterTenant :isa(Registry::DAO::WorkflowStep) {
    use Carp qw(carp croak);

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my $run = $workflow->latest_run($db);

        my $profile = $run->data;

        my $user_data = delete $profile->{users};

        # first we wanna create the Registry user account for our tenant
        my $primary_user =
          Registry::DAO::User->find_or_create( $db, $user_data->[0] );
        unless ($primary_user) {
            croak 'Could not create primary user';
        }

        my $tenant = Registry::DAO::Tenant->create( $db, $profile );
        $db->query( 'SELECT clone_schema(dest_schema => ?)', $tenant->slug );

        $tenant->set_primary_user( $db, $primary_user );

        my $tx = $db->begin;
        for my $data ( $user_data->@* ) {
            if ( my $user = Registry::DAO::User->find( $db, $data ) ) {
                $db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)',
                    $tenant->slug, $user->id );
            }
            else {
                Registry::DAO::User->create( $tenant->dao($db)->db, $data );
            }
        }

        for my $slug (
            qw(user-creation session-creation event-creation location-creation project-creation)
          )
        {
            my $workflow =
              Registry::DAO::Workflow->find( $db, { slug => $slug } );
            $db->query(
                'SELECT copy_workflow(dest_schema => ?, workflow_id => ?)',
                $tenant->slug, $workflow->id );

        }
        $tx->commit;

        if ( $run->has_continuation ) {
            my ($continuation) = $run->continuation($db);
            my $tenants = $continuation->data->{tenants} // [];
            push $tenants->@*, $tenant->id;
            $continuation->update_data( $db, { tenants => $tenants } );
        }

        # return the data to be stored in the workflow run
        return { tenant => $tenant->id };
    }
}

class Registry::DAO::CreateEvent :isa(Registry::DAO::WorkflowStep) {

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my ($run)      = $workflow->latest_run($db);
        my $data       = $run->data;

        # grab stuff that might have come from a continuation
        if ( $data->{locations} ) {
            $data->{location_id} //= $data->{locations}->[0];
        }

        if ( $data->{users} ) {
            $data->{teacher_id} //= $data->{users}->[0];
        }

        if ( $data->{projects} ) {
            $data->{project_id} //= $data->{projects}->[0];
        }

        # only include keys that have values
        my @keys = grep $data->{$_} => qw(
          time
          duration
          location_id
          project_id
          teacher_id
          metadata
          notes
        );

        my $event = Registry::DAO::Event->create( $db, { $data->%{@keys}, } );

        if ( $run->has_continuation ) {
            my ($continuation) = $run->continuation($db);
            my $events = $continuation->data->{events} // [];
            push $events->@*, $event->id;
            $continuation->update_data( $db, { events => $events } );
        }

        return { event => $event->id };
    }
}

class Registry::DAO::CreateSession :isa(Registry::DAO::WorkflowStep) {

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my ($run)      = $workflow->latest_run($db);

        my $data   = $run->data;
        my $events = $data->{events};

        # Mojolicious unwinds form posts of only one value
        $events = [$events] unless ref $events eq 'ARRAY';

        my $session = Registry::DAO::Session->create( $db,
            { $data->%{ 'name', 'metadata', 'notes' } } );
        $session->add_events( $db, $events->@* );

        if ( $run->has_continuation ) {
            my ($continuation) = $run->continuation($db);
            my $sessions = $continuation->data->{sessions} // [];
            push $sessions->@*, $session->id;
            $continuation->update_data( $db, { sessions => $sessions } );
        }

        return { session => $session->id };
    }
}

class Registry::DAO::CreateUser :isa(Registry::DAO::WorkflowStep) {

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my ($run)      = $workflow->latest_run($db);

        my $data = $run->data;

        my $user = Registry::DAO::User->create( $db,
            { $data->%{ 'username', 'password' } } );

        $run->update_data(
            $db,
            {
                password => '',
                passhash => $user->passhash,
                id       => $user->id,
            }
        );

        if ( $run->has_continuation ) {
            my ($continuation) = $run->continuation($db);
            my $users = $continuation->data->{users} // [];
            push $users->@*, { id => $user->id };
            $continuation->update_data( $db, { users => $users } );
        }

        return { user => $user->id };
    }
}

class Registry::DAO::CreateWorkflow :isa(Registry::DAO::WorkflowStep) {
    use Carp qw(croak);

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my $run        = $workflow->latest_run($db);
        my $data       = $run->data;

        # Validate required fields
        croak "Missing required field: name" unless $data->{name};
        croak "Missing required field: slug" unless $data->{slug};
        croak "Missing required field: steps"
          unless $data->{steps} && ref $data->{steps} eq 'ARRAY';

        # Create the new workflow
        my $new_workflow = Registry::DAO::Workflow->create(
            $db,
            {
                name        => $data->{name},
                slug        => $data->{slug},
                description => $data->{description} // '',
            }
        );

        # Handle steps
        my $steps = $data->{steps};

        # Normalize steps to array if it's not already
        $steps = [$steps] unless ref $steps eq 'ARRAY';

        # Add steps to the workflow
        my $first_step;
        my $previous_step;

        # Process steps in the order they appear in the array
        for my $step_data (@$steps) {

            # Validate required step fields
            croak "Missing required field: slug in step"
              unless $step_data->{slug};

            # Prepare step data
            my $step_create_data = {
                workflow_id => $new_workflow->id,
                slug        => $step_data->{slug},
                description => $step_data->{description} // '',
                template_id =>
                  $self->_get_template_id( $db, $step_data->{template} )
                  // undef,
                class => $step_data->{class} // 'Registry::DAO::WorkflowStep',
            };

            # Add dependency if we have a previous step
            if ($previous_step) {
                $step_create_data->{depends_on} = $previous_step->id;
            }

            # Create the step
            my $step =
              Registry::DAO::WorkflowStep->create( $db, $step_create_data );

            # Save first step reference
            $first_step //= $step;

            # Update previous step for the next iteration
            $previous_step = $step;
        }

        # Set the workflow's first_step field
        if ($first_step) {
            $db->update(
                'workflows',
                { first_step => $first_step->slug },
                { id         => $new_workflow->id }
            );
        }

        # Update the workflow run with the created workflow ID
        $run->update_data(
            $db,
            {
                workflow_id => $new_workflow->id,
                created     => 1,
            }
        );

        # Handle continuation if present
        if ( $run->has_continuation ) {
            my ($continuation) = $run->continuation($db);
            my $workflows = $continuation->data->{workflows} // [];
            push @$workflows, $new_workflow->id;
            $continuation->update_data( $db, { workflows => $workflows } );
        }

        return {
            workflow => $new_workflow->id,
            created  => 1,
        };
    }

    # Helper method to find a template ID by slug
    method _get_template_id( $db, $template_slug ) {
        return unless $template_slug;

        my $result =
          $db->select( 'templates', ['id'], { slug => $template_slug } )->hash;

        return $result ? $result->{id} : undef;
    }
}

