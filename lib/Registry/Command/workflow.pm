use v5.34.0;
use utf8;
use Object::Pad;
use experimental qw(try);

class Registry::Command::workflow :isa(Mojolicious::Command) {
    use Carp          qw(carp);
    use Mojo::File    qw(path);
    use Registry::DAO qw(Workflow);
    use YAML::XS      qw(Load);

    field $app :param = undef;

    field $description :reader = 'Workflow management commands';
    field $usage :reader       = <<~"END";
        usage: $0 workflow <tenant> <command> [<args>]

          list available tenants: $0 tenant list

          commands:
            * list - list available workflows
            * show - show details about a workflow
            * import - import workflows from YAML files
            * export - export a workflow to YAML

        END

    field $dao;
    ADJUST { $dao = $self->app->dao }

    method list () {
        my @workflows = $dao->find( Workflow, {} );
        say "Workflows:";
        say sprintf '  - %s (%s - %s)', $_->slug, $_->name, $_->id
          for sort { $a->slug cmp $b->slug } @workflows;

        return;
    }

    method show ($slug) {

        my $workflow = $dao->find( Workflow, { slug => $slug } );

        say <<~"END";

            # ${ \$workflow->name } (${ \$workflow->id })

            ${ \$workflow->description	}
            END

        my @steps = $dao->query( <<~END_SQL, $workflow->id, $workflow->id );
            WITH RECURSIVE step_tree AS (
                -- Base case: steps with no dependencies
                SELECT ws.*, 0 as level
                FROM workflow_steps ws
                WHERE ws.workflow_id = ?
                AND ws.depends_on IS NULL

                UNION ALL

                -- Recursive case: steps that depend on previous steps
                SELECT ws.*, st.level + 1
                FROM workflow_steps ws
                JOIN step_tree st ON ws.depends_on = st.id
                WHERE ws.workflow_id = ?
            )
            SELECT st.*, t.id as template_id, t.name as template_name
            FROM step_tree st
            LEFT JOIN templates t ON t.id = st.template_id
            ORDER BY level, slug;
            END_SQL

        say "Steps:";
        for my $step (@steps) {

            my $template =
              $step->{template_name}
              ? "$step->{template_name} ($step->{template_id})"
              : '[no template found]';

            print <<~"END";
				* /${\$workflow->slug}/:run/$step->{slug} ($step->{id})
				  - Template: $template
				  - Description: $step->{description}
				END
        }

        print "\n";

        return;
    }

    method import (@files) {
        unless ( scalar @files ) {
            @files = $self->app->home->child('workflows')
              ->list_tree->grep(qr/\.ya?ml$/)->each;
        }
        for my $file (@files) {
            my $yaml = $file->slurp;

            next if Load($yaml)->{draft};
            try {
                my $workflow = Workflow->from_yaml( $dao, $yaml );
                say sprintf "Imported workflow '%s' (%s) with %d steps",
                  $workflow->name,
                  $workflow->slug,
                  scalar @{ Load($yaml)->{steps} };
            }
            catch ($e) {
                carp "Error importing workflow: $e";
            }
        }
    }

    method export ( $slug = undef, $file = undef ) {
        if ($slug) {
            my $workflow = $dao->find( Workflow, { slug => $slug } );
            die "Workflow '$slug' not found" unless $workflow;
            my $yaml = $workflow->to_yaml($dao);

            if ( defined $file ) {
                path($file)->spew($yaml);
            }
            else {
                say $yaml;
            }
        }
        else {
            my @workflows = $dao->find( Workflow, {} );
            my $home      = $self->app->home;
            for my $workflow (@workflows) {
                my $yaml = $workflow->to_yaml($dao);
                $home->child( 'workflows', $workflow->slug . '.yml' )
                  ->spew($yaml);
            }
        }
    }

    method run( $cmd, $schema, @args ) {
        $dao = $dao->connect_schema($schema);

        if ( my $method = $self->can($cmd) ) {
            return $self->$method(@args);
        }

        die <<~"END";
        Unknown command `workflow $cmd` ... did you mean `$0 workflow $schema $cmd`?

        $usage
        END
    }
}

