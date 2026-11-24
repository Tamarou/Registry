# ABOUTME: Minion job that continues a parked workflow run, in its tenant's schema, from its latest step.
# ABOUTME: Runs each next step on the run's own data until the run completes or a step needs a person.
use 5.42.0;
use Object::Pad;

class Registry::Job::ContinueWorkflowRun {
    use Registry::DAO::WorkflowRun;

    sub register ($class, $app) {
        $app->minion->add_task( continue_workflow_run => sub ($job, @args) {
            $class->new->run( $job, @args );
        } );
    }

    method run ( $job, $args ) {
        my ( $tenant, $run_id ) = $args->@{qw(tenant run_id)};
        my $db  = $job->app->dao->connect_schema($tenant)->db;
        my $run = Registry::DAO::WorkflowRun->find( $db, { id => $run_id } );

        while ( !$run->completed($db) ) {
            my $step   = $run->next_step($db) or last;
            my $result = $run->process( $db, $step, $run->data );
        }

        return $job->finish( {
            run_id     => $run_id,
            stopped_at => $run->latest_step($db)->slug,
            reason     => 'completed',
        } );
    }
}
