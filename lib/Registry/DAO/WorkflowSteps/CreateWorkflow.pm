use 5.40.2;
use experimental 'signatures', 'try', 'builtin';
use Object::Pad;

class Registry::DAO::WorkflowSteps::CreateWorkflow :isa(Registry::DAO::WorkflowStep) {

use Registry::DAO::Workflow;
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