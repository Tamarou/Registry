# ABOUTME: Minion job that continues a parked workflow run, in its tenant's schema, from its latest step.
# ABOUTME: Runs each next step on the run's own data until the run completes or a step needs a person.
use 5.42.0;
use Object::Pad;

class Registry::Job::ContinueWorkflowRun {
    use Mojo::Promise;
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
            my $result = _settled( $run->process( $db, $step, $run->data ) );

            # A step that did not advance the run is waiting on a person.
            return $job->finish( {
                run_id => $run_id, stopped_at => $step->slug, reason => 'needs_person' } )
                if $result->{stay} || $result->{errors} || $result->{_validation_errors};
        }

        return $job->finish( {
            run_id     => $run_id,
            stopped_at => $run->latest_step($db)->slug,
            reason     => 'completed',
        } );
    }

    # A step that talks to Stripe returns a promise. The job runs outside the
    # daemon's loop, so waiting on it here settles it; a rejection dies.
    sub _settled ($result) {
        return $result unless $result isa Mojo::Promise;
        my ( $value, $error, $rejected );
        $result->then( sub ($v) { $value = $v },
                       sub ($e) { ( $error, $rejected ) = ( $e, 1 ) } )->wait;
        die $error if $rejected;
        return $value;
    }
}
