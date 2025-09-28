# ABOUTME: Base controller class for Registry application using Object::Pad
# ABOUTME: Provides common functionality like workflow handling and template rendering
use 5.40.2;
use utf8;
use Object::Pad;

class Registry::Controller :isa(Mojolicious::Controller) {
    use Carp ();
    use File::Spec ();

    my $find_template = method($name) {
        my $dao = $self->app->dao;
        $dao->find( 'Registry::DAO::Template', { name => $name } );
    };

    method log { $self->app->log }


    method workflow ( $slug = $self->param('workflow') ) {
        return $slug if $slug isa Registry::DAO::Workflow;
        Carp::confess "Missing workflow parameter" unless $slug;

        my $dao      = $self->app->dao;
        my $workflow = $dao->find( Workflow => { slug => $slug } );
        unless ($workflow) {
            Carp::confess sprintf 'Workflow %s not found in tenant %s', $slug,
              $dao->current_tenant;
        }
        return $workflow;
    }

    # TODO make this smarter about Registry things like workflows and steps etc.
    method render(%args) {
        my $dao = $self->app->dao;

        if ( $args{workflow} ) {
            if ( my $workflow = $self->workflow( $args{workflow} ) ) {
                $args{step} //=
                  $self->workflow($workflow)->first_step( $dao->db );
            }
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

                # Check if a file-based template exists first
                my $renderer = $self->app->renderer;
                my $file_template_exists = 0;
                for my $template_dir (@{$renderer->paths}) {
                    my $potential_path = File::Spec->catfile($template_dir, "$name.html.ep");
                    if (-f $potential_path) {
                        $file_template_exists = 1;
                        last;
                    }
                }

                # If file template exists, prefer it over database template to preserve layout functionality
                if ($file_template_exists) {
                    return $self->SUPER::render( template => $name, %args );
                }

                # Only use database template if no file template exists
                unless ( $template = $self->$find_template($name) ) {
                    return $self->SUPER::render( template => $name, %args );
                }
            }
            return $self->SUPER::render( inline => $template->content, %args );
        }

        $self->SUPER::render(%args);
    }
}

1;
