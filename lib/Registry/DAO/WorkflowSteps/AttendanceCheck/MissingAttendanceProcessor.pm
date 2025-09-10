use 5.40.2;
use experimental qw(try);
use Object::Pad;

class Registry::DAO::WorkflowSteps::AttendanceCheck::MissingAttendanceProcessor :isa(Registry::DAO::WorkflowStep) {
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
                
                my $result = $self->check_tenant_missing_attendance($db, $schema);
                $processed_count++;
                $notifications_sent += $result->{notifications_sent} || 0;
            }
            catch ($e) {
                warn "Error processing missing attendance for tenant $schema: $e";
            }
        }
        
        $run->update_data($db, {
            missing_attendance_processed => $processed_count,
            missing_attendance_notifications => $notifications_sent
        });
        
        return;
    }
    
    method check_tenant_missing_attendance($db, $schema) {
        my $events_missing_attendance = Registry::DAO::Event->find_events_missing_attendance($db);
        my $notifications_sent = 0;
        
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
        
        return { notifications_sent => $notifications_sent };
    }
}