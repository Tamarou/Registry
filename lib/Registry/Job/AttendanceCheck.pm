use 5.40.2;
use utf8;
use experimental qw(try);
use Object::Pad;

class Registry::Job::AttendanceCheck {
    use Carp qw( croak );
    use DateTime;
    use Registry::DAO;
    use Registry::DAO::Event;
    use Registry::DAO::Attendance;
    use Registry::DAO::Notification;
    use Registry::DAO::UserPreference;
    
    # Register this job with Minion
    sub register ($class, $app) {
        $app->minion->add_task(attendance_check => sub ($job, @args) {
            $class->new->run($job, @args);
        });
    }
    
    # Main job execution method
    method run ($job, @args) {
        my $opts = $args[0] || {};
        
        $job->app->log->info("Starting attendance check job");
        
        try {
            # Get database connection
            my $dao = $job->app->dao;
            my $db = $dao->db;
            
            # Check all tenant schemas
            my $tenants = Registry::DAO::Tenant->get_all_tenant_schemas($db);
            
            for my $tenant (@$tenants) {
                my $schema = $tenant->{slug};
                next if $schema eq 'registry'; # Skip registry schema
                
                $job->app->log->debug("Checking attendance for tenant: $schema");
                
                # Set schema search path
                $db->query("SET search_path TO $schema, registry, public");
                
                $self->check_tenant_attendance($job, $db, $schema);
            }
            
            $job->app->log->info("Attendance check job completed successfully");
            
            # Schedule next run in 1 minute
            $job->app->minion->enqueue('attendance_check', [], {
                delay => 60,
                attempts => 3,
                priority => 5
            });
        }
        catch ($e) {
            $job->app->log->error("Attendance check job failed: $e");
            
            # Still schedule next run even if this one failed
            $job->app->minion->enqueue('attendance_check', [], {
                delay => 60,
                attempts => 3,
                priority => 5
            });
            
            $job->fail($e);
        }
    }
    
    # Check attendance for a specific tenant
    method check_tenant_attendance ($job, $db, $schema) {
        # Find events that started in the last 15 minutes and don't have attendance records
        my $events_missing_attendance = Registry::DAO::Event->find_events_missing_attendance($db);
        
        for my $event (@$events_missing_attendance) {
            $job->app->log->debug("Found event missing attendance: $event->{id} ($event->{title})");
            
            # Get teacher for this event
            my $teacher_id = $event->{teacher_id};
            next unless $teacher_id;
            
            # Check if teacher wants attendance notifications
            if (Registry::DAO::UserPreference->wants_notification(
                $db, $teacher_id, 'attendance_missing', 'email'
            )) {
                # Send email notification
                Registry::DAO::Notification->send_attendance_missing(
                    $db, $teacher_id, $event, channel => 'email'
                );
                $job->app->log->info("Sent attendance missing email to teacher $teacher_id for event $event->{id}");
            }
            
            if (Registry::DAO::UserPreference->wants_notification(
                $db, $teacher_id, 'attendance_missing', 'in_app'
            )) {
                # Send in-app notification
                Registry::DAO::Notification->send_attendance_missing(
                    $db, $teacher_id, $event, channel => 'in_app'
                );
                $job->app->log->info("Sent attendance missing in-app notification to teacher $teacher_id for event $event->{id}");
            }
        }
        
        # Find events starting soon (next 5 minutes) to send reminders
        my $events_starting_soon = Registry::DAO::Event->find_events_starting_soon($db);
        
        for my $event (@$events_starting_soon) {
            $job->app->log->debug("Found event starting soon: $event->{id} ($event->{title})");
            
            # Get teacher for this event
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
                # Send email reminder
                Registry::DAO::Notification->send_attendance_reminder(
                    $db, $teacher_id, $event, channel => 'email'
                );
                $job->app->log->info("Sent attendance reminder email to teacher $teacher_id for event $event->{id}");
            }
            
            if (Registry::DAO::UserPreference->wants_notification(
                $db, $teacher_id, 'attendance_reminder', 'in_app'
            )) {
                # Send in-app reminder
                Registry::DAO::Notification->send_attendance_reminder(
                    $db, $teacher_id, $event, channel => 'in_app'
                );
                $job->app->log->info("Sent attendance reminder in-app notification to teacher $teacher_id for event $event->{id}");
            }
        }
    }
}