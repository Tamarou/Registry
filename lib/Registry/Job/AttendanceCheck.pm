use 5.42.0;
use utf8;

use Object::Pad;

class Registry::Job::AttendanceCheck {
    use Registry::Job::Recurring;
    use Registry::Job::ContinueWorkflowRun;
    use Registry::DAO::Workflow;
    use Registry::DAO::WorkflowRun;

    # Register this job with Minion; Recurring queues each next check.
    sub register ($class, $app) {
        Registry::Job::Recurring->add_task( $app, attendance_check => sub ($job, @args) {
            $class->new->run($job, @args);
        });
    }

    # Starts an attendance-check run in the platform schema and has the run
    # driver take it to the end. A step that dies fails this check; the next
    # check is its retry, so no admin is asked to finish it by hand.
    method run ($job, @args) {
        my $db       = $job->app->dao->db;
        my $workflow = Registry::DAO::Workflow->find( $db, { slug => 'attendance-check' } )
            or die "Workflow 'attendance-check' not found\n";
        my $run = $workflow->new_run( $db, {} );
        Registry::Job::ContinueWorkflowRun->new->run( $job, { tenant => 'registry', run_id => $run->id },
            alert_admins => 0 );

        # Finish with the tenants covered and skipped, as the other sweeps do.
        # Re-read: the steps wrote their results through their own run object.
        my $data = Registry::DAO::WorkflowRun->find( $db, { id => $run->id } )->data;
        my %skipped = map { $_->{slug} => $_ }
            map { @{ $data->{$_} // [] } } qw( missing_attendance_skipped upcoming_events_skipped );
        $job->finish( {
            tenants_covered => [ grep { !$skipped{$_} } @{ $data->{tenant_schemas} // [] } ],
            tenants_skipped => [ map { $skipped{$_} } sort keys %skipped ],
        } );
    }
}
