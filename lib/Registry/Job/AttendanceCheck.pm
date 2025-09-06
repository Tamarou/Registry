use 5.40.2;
use utf8;
use experimental qw(try);
use Object::Pad;

class Registry::Job::AttendanceCheck {
    use Registry::Job::WorkflowExecutor;
    
    # Register this job with Minion
    sub register ($class, $app) {
        $app->minion->add_task(attendance_check => sub ($job, @args) {
            $class->new->run($job, @args);
        });
    }
    
    # Main job execution method - now delegates to WorkflowExecutor
    method run ($job, @args) {
        my $opts = $args[0] || {};
        
        # Convert to workflow executor format
        my $workflow_opts = {
            workflow_slug => 'attendance-check',
            context => $opts->{context} || {},
            reschedule => {
                enabled => 1,
                delay => 60,        # 1 minute
                attempts => 3,
                priority => 5
            }
        };
        
        # Delegate to generic workflow executor
        my $executor = Registry::Job::WorkflowExecutor->new;
        $executor->run($job, $workflow_opts);
    }
    
    # Helper method to start attendance check
    sub start_monitoring ($class, $app, %opts) {
        return Registry::Job::WorkflowExecutor->enqueue_workflow(
            $app, 
            'attendance-check',
            reschedule => {
                enabled => 1,
                delay => $opts{interval} || 60,
                attempts => 3,
                priority => 5
            },
            %opts
        );
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