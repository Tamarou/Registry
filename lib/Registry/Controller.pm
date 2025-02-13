use 5.40.0;
use Object::Pad;

class Registry::Controller :isa(Mojolicious::Controller) {
    use Carp ();

    my $find_template = method($name) {
        my $dao = $self->app->dao;
        $dao->find( 'Registry::DAO::Template', { name => $name } );
    };

    method log { $self->app->log }

    method workflow ( $slug = $self->param('workflow') ) {
        return $slug if $slug isa Registry::DAO::Workflow;

        my $dao = $self->app->dao;
        return $dao->find( Workflow => { slug => $slug } );
    }

    # TODO make this smarter about Registry things like workflows and steps etc.
    method render(%args) {
        my $dao = $self->app->dao;

        if ( my $workflow = $self->workflow( $args{workflow} ) ) {
            $args{step} //= $self->workflow($workflow)->first_step( $dao->db );
        }

        if ( my $step = $args{step} ) {
            unless ( $step isa Registry::DAO::WorkflowStep ) {
                my $workflow = $self->workflow( $args{workflow} );
                die "no workflow" unless $workflow;
                $step = $workflow->get_step( $dao->db, { slug => $step } );
            }
            $args{template} //= $step->template( $dao->db );
        }

        if ( my $template = $args{template} ) {
            unless ( $template isa Registry::DAO::Template ) {
                my $name = $template;
                unless ( $template = $self->$find_template($name) ) {
                    Carp::cluck "Could not find template '$name'";
                    return $self->SUPER::render( template => $name, %args );
                }
            }
            return $self->SUPER::render( inline => $template->html, %args );
        }

        $self->SUPER::render(%args);
    }
}
