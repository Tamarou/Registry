use 5.42.0;

use Object::Pad;

class Registry::DAO::WorkflowSteps::AttendanceCheck::MissingAttendanceProcessor :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Event;
    use Registry::DAO::Notification;
    use Registry::DAO::UserPreference;

    method process($db, $continuation, $run = undef) {
        $run //= do { my ($w) = $self->workflow($db); $w->latest_run($db) };
        my $data = $run->data || {};
        my $tenant_schemas = $data->{tenant_schemas} || [];
        
        my $processed_count = 0;
        my @skipped;
        my $notifications_sent = 0;

        # The loop points the search_path at each tenant schema in turn; a
        # tenant schema has its own workflow_runs, so restore the caller's
        # search_path before recording the result on this run.
        my $search_path = $db->query('SHOW search_path')->array->[0];
        
        for my $schema (@$tenant_schemas) {
            try {
                # Set schema search path. Quote the tenant schema so names
                # containing hyphens (e.g. "my-tenant") stay valid.
                my $quoted = $db->dbh->quote_identifier($schema);
                # No registry fallback: a tenant missing a table must fail, not reread registry.
                $db->query("SET search_path TO $quoted, public");
                
                my $result = $self->check_tenant_missing_attendance($db, $schema);
                $processed_count++;
                $notifications_sent += $result->{notifications_sent} || 0;
            }
            catch ($e) {
                ( my $reason = "$e" ) =~ s{\s+}{ }g;
                push @skipped, { slug => $schema, error => $reason };
            }
        }

        $db->query("SET search_path TO $search_path");
        
        $run->update_data($db, {
            missing_attendance_processed => $processed_count,
            missing_attendance_notifications => $notifications_sent,
            missing_attendance_skipped => \@skipped
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