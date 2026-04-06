# ABOUTME: Base controller class for Registry application using Object::Pad
# ABOUTME: Provides common functionality like workflow handling and template rendering
use 5.42.0;
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
    method render(@args) {
        # Handle Mojolicious's include helper which passes a positional
        # template name as the first argument (odd arg count).
        unshift @args, 'template' if @args % 2;
        my %args = @args;
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

                # DB-first: check for tenant-customized template
                my $db_templates = $self->stash('_db_templates');
                if ($db_templates && !exists $db_templates->{$name}) {
                    # Lazy load: query DB on first access, cache in stash
                    if ( $template = $self->$find_template($name) ) {
                        $db_templates->{$name} = $template->content;
                    } else {
                        $db_templates->{$name} = undef; # Cache the miss
                    }
                }

                if ($db_templates && $db_templates->{$name}) {
                    return $self->SUPER::render( inline => $db_templates->{$name}, %args );
                }

                # Fall back to filesystem template (platform default)
                return $self->SUPER::render( template => $name, %args );
            }
            return $self->SUPER::render( inline => $template->content, %args );
        }

        $self->SUPER::render(%args);
    }
}

1;
