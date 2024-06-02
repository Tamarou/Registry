use 5.38.0;
use Object::Pad;

class Registry::Controller::Workflows : isa(Mojolicious::Controller) {

    method workflow ( $slug = $self->param('workflow') ) {
        my $dao = $self->app->dao;
        return $dao->find( Workflow => { slug => $slug } );
    }

    method run ( $id = $self->param('run') ) {
        my $dao = $self->app->dao;
        ( $dao->find( WorkflowRun => { id => $id } ) )[0];
    }

    method new_run ( $workflow, $config //= {} ) {
        my $dao  = $self->app->dao;
        my $step = $workflow->first_step( $dao->db );
        my $run  = $workflow->new_run( $dao->db, $config );
        my $data = $self->req->params->to_hash;
        $run->process( $dao->db, $step, $data );
        return $run;
    }

    method index() {
        my $dao = $self->app->dao;
        my ($workflow) = $self->workflow();

        # TODO grab this from the first workflow first step
        my $template =
          '<form action="<%= $action %>"><button>Start</button></form>';
        $self->render(
            inline => $template,
            action => $self->url_for('workflow_start')
        );
    }

    method start_workflow() {
        my $dao = $self->app->dao;
        my $run = $self->new_run( $self->workflow() );
        $self->redirect_to(
            $self->url_for(
                'workflow_step',
                run  => $run->id,
                step => $run->next_step( $dao->db )->slug,
            )
        );
    }

    method get_workflow_run_step {
        my $dao = $self->app->dao;
        my $run = $self->run();

        # TODO grab the template from the workflow step
        my $template = q{
            % my $events_url = url_for "workflow_callcc", target => 'event-creation';
            <form action="<%= $action %>">
                <a rel="create-page event" href="<%= $events_url %>">Add Event</a>
            </form>
        };

        return $self->render(
            inline => $template,
            status => 200,
            action => $self->url_for('workflow_process_step'),
        );
    }

    method process_workflow_run_step {
        my $dao = $self->app->dao;

        my ($run) = $dao->find(
            WorkflowRun => {
                id => $self->param('run'),
            }
        );

        my ($step)   = $run->next_step( $dao->db );
        my ($latest) = $run->latest_step( $dao->db );
        warn "done" if $run->completed( $dao->db );
        die "No step found" unless $step;

        die "Wrong step expected ${\$step->slug}"
          unless $step->slug eq $self->param('step');

        my $data = $self->req->params->to_hash;
        $run->process( $dao->db, $step, $data );

        # if we're not done, redirect to the next step
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

        # otherwise, we're done
        return $self->render( text => 'DONE', status => 201 );
    }

    method start_continuation {
        my $dao = $self->app->dao;
        my ($workflow) = $dao->find(
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
