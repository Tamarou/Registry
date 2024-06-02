use 5.38.0;
use Object::Pad;

class Registry::Controller::Workflows : isa(Mojolicious::Controller) {

    method workflow_url ($workflow) {
        return $self->url_for( $workflow->slug );
    }

    method workflow_start_url ($step) {
        my $name = $self->param('workflow');
        return $self->url_for( "${name}_start", step => $step->slug );
    }

    method workflow_run_step_url ( $run, $step ) {
        my $name = $self->param('workflow');
        return $self->url_for(
            "${name}_run_step",
            run  => $run->id,
            step => $step->slug
        );
    }

    method workflow_process_step_url ( $run, $step ) {
        my $name = $self->param('workflow');
        return $self->url_for(
            "${name}_process_step",
            run  => $run->id,
            step => $step->slug
        );
    }

    method index() {
        my $dao = $self->app->dao;
        my ($workflow) = $dao->find(
            Workflow => {
                slug => $self->param('workflow')
            }
        );

        # TODO grab the template for the first step to render
        my $step = $workflow->first_step( $dao->db );
        $self->render(
            inline => '<form action="<%= $action %>"></form>',
            action => $self->workflow_start_url($step),
        );
    }

    method start_workflow() {
        my $dao = $self->app->dao;
        my ($workflow) = $dao->find(
            Workflow => {
                slug => $self->param('workflow')
            }
        );

        my $step = $workflow->first_step( $dao->db );
        my $run  = $workflow->new_run( $dao->db );
        my $data = $self->req->params->to_hash;
        $run->process( $dao->db, $step, $data );
        $self->redirect_to(
            $self->workflow_run_step_url( $run, $run->next_step( $dao->db ) ) );
    }

    method get_workflow_run_step {
        my $dao = $self->app->dao;

        my ($run) = $dao->find(
            WorkflowRun => {
                id => $self->param('run'),
            }
        );

        my $step = $run->next_step( $dao->db );
        die "Wrong step expected $step"
          unless $step->slug eq $self->param('step');

        return $self->render(
            inline => '<form action="<%= $action %>"></form>',
            status => 200,
            action => $self->workflow_process_step_url( $run, $step )
        );
    }

    method process_workflow_run_step {
        my $dao = $self->app->dao;

        my ($run) = $dao->find(
            WorkflowRun => {
                id => $self->param('run'),
            }
        );

        my $step = $run->next_step( $dao->db );
        die "Wrong step expected $step"
          unless $step->slug eq $self->param('step');

        my $data = $self->req->params->to_hash;
        $run->process( $dao->db, $step, $data );

        unless ( $run->is_complete( $dao->db ) ) {
            my $workflow = $run->workflow( $dao->db );
            my $next     = $run->next_step( $dao->db );
            return $self->redirect_to(
                $self->workflow_run_step_url( $run, $next ) );
        }

        return $self->render( text => 'DONE', status => 201 );
    }
}