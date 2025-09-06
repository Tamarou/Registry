use 5.40.2;
use utf8;
use Object::Pad;

class Registry::Command::schema :isa(Mojolicious::Command) {
    use Registry::DAO::OutcomeDefinition;
    use Mojo::JSON qw(encode_json);
    use experimental 'try';

    field $description :reader = 'Outcome definition (schema) management commands';
    field $usage :reader = <<~"END";
        usage: $0 schema <tenant> <command> [<args>]

          list available tenants: $0 tenant list

          commands:
            * list - list available outcome definitions
            * show - show details about an outcome definition  
            * import - import outcome definitions from the filesystem
            * load - alias for import

        END

    method run($cmd, $schema, @args) {
        my $dao = $self->app->dao($schema // 'registry');

        if ($cmd eq 'list') {
            my @definitions = $dao->find('Registry::DAO::OutcomeDefinition', {});
            say sprintf '%s (%s)', $_->name, $_->id
              for sort { $a->name cmp $b->name } @definitions;
            return;
        }

        if ($cmd eq 'show') {
            my ($id) = @args;
            my $definition = $dao->find('Registry::DAO::OutcomeDefinition', { id => $id });
            
            unless ($definition) {
                say "Outcome definition with ID '$id' not found";
                return;
            }

            say <<~"END";

            # Outcome Definition ${ \$definition->name } (${ \$definition->id })

            Created: ${ \$definition->created_at }
            Description: ${ \$definition->description // 'No description' }

            Schema:
            ```
            ${ \encode_json($definition->schema) }
            ```
            END

            return;
        }

        # Handle command aliases
        $cmd = 'load' if $cmd eq 'import';

        if (my $method = $self->can($cmd)) {
            return $self->$method($schema // 'registry', @args);
        }

        die <<~"END";
        Unknown command `schema $cmd` ... did you mean `$0 schema $schema $cmd @args`?

        $usage
        END
    }

    method load($schema = 'registry', @args) {
        my $dao = $self->app->dao($schema);
        my @schemas = $self->app->home->child('schemas')
          ->list->grep(qr/\.json$/)->each;

        for my $file (@schemas) {
            try {
                my $outcome = Registry::DAO::OutcomeDefinition->import_from_file($dao, $file);
                say sprintf "Imported outcome definition '%s'", $outcome->name;
            }
            catch ($e) {
                say sprintf "Failed to import schema from '%s': %s", 
                  $file->to_rel('schemas'), $e;
            }
        }
        return;
    }
}