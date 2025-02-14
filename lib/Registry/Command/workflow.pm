use v5.40.0;
use utf8;
use Object::Pad;

class Registry::Command::workflow :isa(Mojolicious::Command) {
    field $app :param = undef;

    field $description :reader = 'Workflow management commands';
    field $usage :reader       = <<~"END";
        usage: $0 workflow <tenant> <command> [<args>]

          list available tenants: $0 tenant list

          commands:
            * list - list available workflows
            * show - show details about a workflow

        END

    method run( $cmd, $schema, @args ) {

        my $dao = $self->app->dao->connect_schema($schema);

        if ( $cmd eq 'list' ) {
            my @workflows = $dao->find( 'Registry::DAO::Workflow', {} );
            say "Workflows:";
            say sprintf '  - %s (%s - %s)', $_->slug, $_->name, $_->id
              for sort { $a->slug cmp $b->slug } @workflows;

            return;
        }

        if ( $cmd eq 'show' ) {
            my ($slug) = @args;

            my $workflow =
              $dao->find( 'Registry::DAO::Workflow', { slug => $slug } );

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

        die <<~"END";
        Unknown command `workflow $cmd` ... did you mean `$0 workflow $schema $cmd`?

        $usage
        END

    }
}

