use 5.40.2;
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

    method load (@args) {
        my $dao = $self->app->dao;
        my @files = Mojo::Home->new->child('templates')
          ->list_tree->grep(qr/\.html\.ep$/)->each;

        for my $file (@files) {
            Registry::DAO::Template->import_from_file( $dao, $file );
            say sprintf "Imported template '%s'",
              $file->to_rel('templates');
        }
        return;
    }

        # Handle command aliases
        $cmd = 'load' if $cmd eq 'import';

        if ( my $method = $self->can($cmd) ) {
            return $self->$method(@args);
        }

        die <<~"END";
        Unknown command `template $cmd` ... did you mean `$0 template $schema $cmd @args`?

        $usage
        END
    }
}

