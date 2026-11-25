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
    # driver take it to the end. A step that dies fails this check.
    method run ($job, @args) {
        my $db       = $job->app->dao->db;
        my $workflow = Registry::DAO::Workflow->find( $db, { slug => 'attendance-check' } )
            or die "Workflow 'attendance-check' not found\n";
        my $run = $workflow->new_run( $db, {} );
        Registry::Job::ContinueWorkflowRun->new->run( $job, { tenant => 'registry', run_id => $run->id } );

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

    # Backward compatibility method for tests
    method check_tenant_attendance ($job, $db, $schema) {
        my $notifications_sent = 0;
        
        # Process events missing attendance
        my $events_missing_attendance = Registry::DAO::Event->find_events_missing_attendance($db);
        for my $event (@$events_missing_attendance) {
            my $teacher_id = $event->{teacher_id};
            next unless $teacher_id;
            
            # Check if teacher wants attendance notifications
            if (Registry::DAO::UserPreference->wants_notification(
                $db, $teacher_id, 'attendance_missing', 'email'
            )) {
                Registry::DAO::Notification->send_attendance_missing(
                    $db, $teacher_id, $event, channel => 'email'
                );
                $notifications_sent++;
            }
            
            if (Registry::DAO::UserPreference->wants_notification(
                $db, $teacher_id, 'attendance_missing', 'in_app'
            )) {
                Registry::DAO::Notification->send_attendance_missing(
                    $db, $teacher_id, $event, channel => 'in_app'
                );
                $notifications_sent++;
            }
        }
        
        # Process events starting soon
        my $events_starting_soon = Registry::DAO::Event->find_events_starting_soon($db);
        for my $event (@$events_starting_soon) {
            my $teacher_id = $event->{teacher_id};
            next unless $teacher_id;
            
            # Check if we already sent a reminder for this event
            next if Registry::DAO::Notification->has_existing_reminder(
                $db, $teacher_id, 'attendance_reminder', $event->{id}
            );
            
            # Check if teacher wants reminder notifications
            if (Registry::DAO::UserPreference->wants_notification(
                $db, $teacher_id, 'attendance_reminder', 'email'
            )) {
                Registry::DAO::Notification->send_attendance_reminder(
                    $db, $teacher_id, $event, channel => 'email'
                );
                $notifications_sent++;
            }
            
            if (Registry::DAO::UserPreference->wants_notification(
                $db, $teacher_id, 'attendance_reminder', 'in_app'
            )) {
                Registry::DAO::Notification->send_attendance_reminder(
                    $db, $teacher_id, $event, channel => 'in_app'
                );
                $notifications_sent++;
            }
        }
        
        return $notifications_sent;
    }
}