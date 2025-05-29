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
            my $tenants = $db->select('registry.tenants', ['slug'])->hashes->to_array;
            
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
        my $events_missing_attendance = $self->find_events_missing_attendance($db);
        
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
        my $events_starting_soon = $self->find_events_starting_soon($db);
        
        for my $event (@$events_starting_soon) {
            $job->app->log->debug("Found event starting soon: $event->{id} ($event->{title})");
            
            # Get teacher for this event
            my $teacher_id = $event->{teacher_id};
            next unless $teacher_id;
            
            # Check if we already sent a reminder for this event
            my $existing_reminder = $db->select(
                'notifications',
                'id',
                {
                    user_id => $teacher_id,
                    type => 'attendance_reminder',
                    'metadata->event_id' => $event->{id}
                }
            )->hash;
            
            next if $existing_reminder; # Already sent reminder
            
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
    
    # Find events that started in the last 15 minutes but don't have attendance records
    method find_events_missing_attendance ($db) {
        my $sql = q{
            SELECT 
                e.id,
                e.teacher_id,
                e.metadata->>'title' as title,
                e.metadata->>'start_time' as start_time,
                e.metadata->>'end_time' as end_time,
                l.name as location_name,
                p.name as program_name,
                COUNT(en.id) as enrolled_count
            FROM events e
            JOIN locations l ON e.location_id = l.id
            JOIN projects p ON e.project_id = p.id
            LEFT JOIN sessions s ON s.project_id = p.id
            LEFT JOIN enrollments en ON en.session_id = s.id AND en.status = 'active'
            WHERE 
                -- Event started in the last 15 minutes
                CAST(e.metadata->>'start_time' AS timestamp) BETWEEN 
                    now() - interval '15 minutes' AND now()
                -- And has no attendance records
                AND NOT EXISTS (
                    SELECT 1 FROM attendance_records ar 
                    WHERE ar.event_id = e.id
                )
                -- And has enrolled students
                AND EXISTS (
                    SELECT 1 FROM enrollments en2 
                    JOIN sessions s2 ON en2.session_id = s2.id 
                    WHERE s2.project_id = e.project_id 
                    AND en2.status = 'active'
                )
            GROUP BY e.id, e.teacher_id, e.metadata, l.name, p.name
            ORDER BY CAST(e.metadata->>'start_time' AS timestamp) DESC
        };
        
        return $db->query($sql)->hashes->to_array;
    }
    
    # Find events starting in the next 5 minutes
    method find_events_starting_soon ($db) {
        my $sql = q{
            SELECT 
                e.id,
                e.teacher_id,
                e.metadata->>'title' as title,
                e.metadata->>'start_time' as start_time,
                e.metadata->>'end_time' as end_time,
                l.name as location_name,
                p.name as program_name,
                COUNT(en.id) as enrolled_count
            FROM events e
            JOIN locations l ON e.location_id = l.id
            JOIN projects p ON e.project_id = p.id
            LEFT JOIN sessions s ON s.project_id = p.id
            LEFT JOIN enrollments en ON en.session_id = s.id AND en.status = 'active'
            WHERE 
                -- Event starts in the next 5 minutes
                CAST(e.metadata->>'start_time' AS timestamp) BETWEEN 
                    now() AND now() + interval '5 minutes'
                -- And has enrolled students
                AND EXISTS (
                    SELECT 1 FROM enrollments en2 
                    JOIN sessions s2 ON en2.session_id = s2.id 
                    WHERE s2.project_id = e.project_id 
                    AND en2.status = 'active'
                )
            GROUP BY e.id, e.teacher_id, e.metadata, l.name, p.name
            ORDER BY CAST(e.metadata->>'start_time' AS timestamp) ASC
        };
        
        return $db->query($sql)->hashes->to_array;
    }
    
    # Find events that started more than 30 minutes ago with no attendance
    method find_events_severely_overdue ($db) {
        my $sql = q{
            SELECT 
                e.id,
                e.teacher_id,
                e.metadata->>'title' as title,
                e.metadata->>'start_time' as start_time,
                e.metadata->>'end_time' as end_time,
                l.name as location_name,
                p.name as program_name,
                COUNT(en.id) as enrolled_count
            FROM events e
            JOIN locations l ON e.location_id = l.id
            JOIN projects p ON e.project_id = p.id
            LEFT JOIN sessions s ON s.project_id = p.id
            LEFT JOIN enrollments en ON en.session_id = s.id AND en.status = 'active'
            WHERE 
                -- Event started more than 30 minutes ago
                CAST(e.metadata->>'start_time' AS timestamp) < now() - interval '30 minutes'
                -- And has no attendance records
                AND NOT EXISTS (
                    SELECT 1 FROM attendance_records ar 
                    WHERE ar.event_id = e.id
                )
                -- And has enrolled students
                AND EXISTS (
                    SELECT 1 FROM enrollments en2 
                    JOIN sessions s2 ON en2.session_id = s2.id 
                    WHERE s2.project_id = e.project_id 
                    AND en2.status = 'active'
                )
            GROUP BY e.id, e.teacher_id, e.metadata, l.name, p.name
            ORDER BY CAST(e.metadata->>'start_time' AS timestamp) ASC
        };
        
        return $db->query($sql)->hashes->to_array;
    }
}