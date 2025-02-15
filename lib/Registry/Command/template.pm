use v5.40.0;
use utf8;
use Object::Pad;

class Registry::Command::template :isa(Mojolicious::Command) {

    field $description :reader = 'Template management commands';
    field $usage :reader       = <<~"END";
        usage: $0 template <tenant> <command> [<args>]

          list available tenants: $0 tenant list

          commands:
            * list - list available templates
            * show - show details about a template
            * import - import templates from the filesystem

        END

    method run( $cmd, $schema, @args ) {
        my $dao = $self->app->dao;

        if ( $cmd eq 'list' ) {
            my @templates = $dao->find( 'Registry::DAO::Template', {} );
            say sprintf '%s (%s)', $_->name, $_->id
              for sort { $a->name cmp $b->name } @templates;

            return;
        }

        if ( $cmd eq 'show' ) {
            my ($id) = @args;
            my $template =
              $dao->find( 'Registry::DAO::Template', { id => $id } );

            say <<~"END";

            # Tepmlate ${ \$template->name } (${ \$template->id })

            Created: ${ \$template->created_at }

            Notes:
                ${ \$template->notes }

            Content:
            ```
            ${ \$template->content	}
            ```
            END

            return;
        }
        if ( $cmd eq 'import' ) {
            Registry::DAO::Template->import_templates( $dao, sub { say @_ } );
            return;
        }

        die <<~"END";
        Unknown command `template $cmd` ... did you mean `$0 template $schema $cmd @args`?

        $usage
        END
    }
}

