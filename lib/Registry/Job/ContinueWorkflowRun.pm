# ABOUTME: Minion job that continues a parked workflow run, in its tenant's schema, from its latest step.
# ABOUTME: Runs each next step on the run's own data until the run completes or a step needs a person.
use 5.42.0;
use Object::Pad;

class Registry::Job::ContinueWorkflowRun {
    use Mojo::Date;
    use Mojo::Promise;
    use Registry::DAO::Tenant;
    use Registry::DAO::WorkflowRun;

    sub register ($class, $app) {
        $app->minion->add_task( continue_workflow_run => sub ($job, @args) {
            $class->new->run( $job, @args );
        } );
    }

    method run ( $job, $args ) {
        my ( $tenant, $run_id ) = ref $args eq 'HASH' ? $args->@{qw(tenant run_id)} : ();
        die "continue_workflow_run needs a tenant and a run_id\n"
            unless defined $tenant && defined $run_id && !ref $tenant && !ref $run_id;
        die "continue_workflow_run: run_id is not a UUID\n"
            unless $run_id =~ /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i;
        # The slug becomes a search_path, so only a known tenant's is used.
        die "continue_workflow_run: tenant is not a registered tenant\n"
            unless Registry::DAO::Tenant->find( $job->app->dao->db, { slug => $tenant } );

        my $db = $job->app->dao->connect_schema($tenant)->db;

        # One driver per run: a second job for it waits here, then finds the
        # run where the first left it. Released however the drive ends.
        my $lock = 'SELECT %s(hashtextextended(?, 0))';
        $db->query( sprintf( $lock, 'pg_advisory_lock' ), $run_id );
        my $done;
        try { $done = $self->_drive( $job, $db, $tenant, $run_id ) }
        catch ($e) {
            $db->query( sprintf( $lock, 'pg_advisory_unlock' ), $run_id );
            die $e;
        }
        $db->query( sprintf( $lock, 'pg_advisory_unlock' ), $run_id );
        return $done;
    }

    method _drive ( $job, $db, $tenant, $run_id ) {
        my $run = Registry::DAO::WorkflowRun->find( $db, { id => $run_id } )
            or die "continue_workflow_run: run not found: $run_id in tenant $tenant\n";

        my $step;
        try {
            while ( !$run->completed($db) ) {
                $step = $run->next_step($db) or last;
                my $result = _settled( $run->process( $db, $step, $run->data ) );

                # A step that did not advance the run is waiting on a person.
                return _finish( $job, $db, $run, $step->slug, 'needs_person' )
                    if $result->{stay} || $result->{errors} || $result->{_validation_errors};
            }
        }
        catch ($e) {
            die $e unless $step;
            # Written down on the run so a run nobody is waiting on is not
            # silently stuck; the last attempt marks it halted for an admin.
            my $attempt = $job->retries + 1;
            $run->update_data( $db, { __driver => {
                step    => $step->slug,
                attempt => $attempt,
                error   => "$e",
                at      => Mojo::Date->new->to_datetime,
                ( $attempt >= $job->info->{attempts} ? ( state => 'halted' ) : () ),
            } } );
            die $e;
        }

        return _finish( $job, $db, $run, $run->latest_step($db)->slug, 'completed' );
    }

    # A drive that ended without dying clears any failure an earlier one recorded.
    sub _finish ( $job, $db, $run, $stopped_at, $reason ) {
        $run->update_data( $db, { __driver => undef } ) if $run->data->{__driver};
        return $job->finish( { run_id => $run->id, stopped_at => $stopped_at, reason => $reason } );
    }

    # A step that talks to Stripe returns a promise. The job runs outside the
    # daemon's loop, so waiting on it here settles it; a rejection dies.
    sub _settled ($result) {
        return $result unless $result isa Mojo::Promise;
        my ( $value, $error, $rejected );
        $result->then( sub ($v) { $value = $v },
                       sub ($e) { ( $error, $rejected ) = ( $e, 1 ) } )->wait;
        die $error if $rejected;
        # A promise that never settled (e.g. waited on inside a running loop)
        # leaves no result; going on would re-run the same step forever.
        die "continue_workflow_run: step did not settle\n" unless ref $value eq 'HASH';
        return $value;
    }
}
