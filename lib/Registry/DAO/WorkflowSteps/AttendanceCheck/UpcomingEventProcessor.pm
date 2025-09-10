use 5.40.2;
use experimental qw(try);
use Object::Pad;

class Registry::DAO::WorkflowSteps::AttendanceCheck::UpcomingEventProcessor :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Event;
    use Registry::DAO::Notification;
    use Registry::DAO::UserPreference;

    method process($db, $continuation) {
        my ($workflow) = $self->workflow($db);
        my ($run) = $workflow->latest_run($db);
        my $data = $run->data || {};
        my $tenant_schemas = $data->{tenant_schemas} || [];
        
        my $processed_count = 0;
        my $notifications_sent = 0;
        
        for my $schema (@$tenant_schemas) {
            try {
                # Set schema search path
                $db->query("SET search_path TO $schema, registry, public");
                
                my $result = $self->check_tenant_upcoming_events($db, $schema);
                $processed_count++;
                $notifications_sent += $result->{notifications_sent} || 0;
            }
            catch ($e) {
                warn "Error processing upcoming events for tenant $schema: $e";
            }
        }
        
        $run->update_data($db, {
            upcoming_events_processed => $processed_count,
            upcoming_events_notifications => $notifications_sent
        });
        
        return;
    }
    
    method check_tenant_upcoming_events($db, $schema) {
        my $events_starting_soon = Registry::DAO::Event->find_events_starting_soon($db);
        my $notifications_sent = 0;
        
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
        
        return { notifications_sent => $notifications_sent };
    }
}