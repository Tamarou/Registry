use 5.40.2;
use utf8;
use experimental qw(signatures try);
use Object::Pad;

class Registry::Controller::ParentDashboard :isa(Registry::Controller) {
    use DateTime;
    use List::Util qw(sum);
    
    # Main parent dashboard
    method index ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden') 
            unless $user->{role} eq 'parent' || $user->{user_type} eq 'parent';
        
        my $db = $c->app->db($c->stash('tenant'));
        
        # Get all dashboard data
        my $dashboard_data = $self->_get_dashboard_data($db, $user->{id});
        
        # Pass data to template
        $c->stash(%$dashboard_data);
        $c->render(template => 'parent_dashboard/index');
    }
    
    # Get upcoming events calendar (HTMX endpoint)
    method upcoming_events ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        
        my $db = $c->app->db($c->stash('tenant'));
        my $days = $c->param('days') || 7; # Default to next 7 days
        
        my $upcoming_events = $self->_get_upcoming_events($db, $user->{id}, $days);
        
        $c->stash(upcoming_events => $upcoming_events);
        $c->render(template => 'parent_dashboard/upcoming_events', layout => undef);
    }
    
    # Get recent attendance (HTMX endpoint)
    method recent_attendance ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        
        my $db = $c->app->db($c->stash('tenant'));
        my $limit = $c->param('limit') || 10;
        
        my $recent_attendance = $self->_get_recent_attendance($db, $user->{id}, $limit);
        
        $c->stash(recent_attendance => $recent_attendance);
        $c->render(template => 'parent_dashboard/recent_attendance', layout => undef);
    }
    
    # Get unread messages count (HTMX endpoint)
    method unread_messages_count ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        
        my $db = $c->app->db($c->stash('tenant'));
        
        require Registry::DAO::Message;
        my $unread_count = Registry::DAO::Message->get_unread_count($db, $user->{id});
        
        $c->render(json => { unread_count => $unread_count });
    }
    
    # Drop enrollment (quick action)
    method drop_enrollment ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        
        my $enrollment_id = $c->param('enrollment_id');
        my $db = $c->app->db($c->stash('tenant'));
        
        try {
            # Verify parent owns this enrollment
            my $enrollment = $db->select('enrollments', '*', { 
                id => $enrollment_id 
            })->hash;
            
            return $c->render(status => 404, text => 'Enrollment not found') unless $enrollment;
            
            # Check if parent has access to this enrollment via family member
            my $family_member = $db->select('family_members', '*', { 
                id => $enrollment->{family_member_id},
                family_id => $user->{id}
            })->hash;
            
            return $c->render(status => 403, text => 'Forbidden') unless $family_member;
            
            # Update enrollment status to cancelled
            $db->update('enrollments', 
                { status => 'cancelled', updated_at => \'now()' },
                { id => $enrollment_id }
            );
            
            # Trigger waitlist processing for this session
            require Registry::Job::ProcessWaitlist;
            $c->app->minion->enqueue('process_waitlist', [$enrollment->{session_id}], {
                attempts => 3,
                priority => 8
            });
            
            if ($c->accepts('', 'html')) {
                $c->flash(success => 'Enrollment cancelled successfully. Waitlist will be processed automatically.');
                return $c->redirect_to('parent_dashboard');
            } else {
                return $c->render(json => { success => 1, message => 'Enrollment cancelled successfully' });
            }
        }
        catch ($e) {
            if ($c->accepts('', 'html')) {
                $c->flash(error => "Failed to cancel enrollment: $e");
                return $c->redirect_to('parent_dashboard');
            } else {
                return $c->render(json => { error => "Failed to cancel enrollment: $e" }, status => 500);
            }
        }
    }
    
    # Private helper methods
    
    # Get all dashboard data
    method _get_dashboard_data ($db, $parent_id) {
        return {
            children => $self->_get_children($db, $parent_id),
            enrollments => $self->_get_active_enrollments($db, $parent_id),
            upcoming_events => $self->_get_upcoming_events($db, $parent_id, 7),
            recent_attendance => $self->_get_recent_attendance($db, $parent_id, 5),
            recent_messages => $self->_get_recent_messages($db, $parent_id, 5),
            waitlist_entries => $self->_get_waitlist_entries($db, $parent_id),
            unread_message_count => $self->_get_unread_message_count($db, $parent_id),
            dashboard_stats => $self->_get_dashboard_stats($db, $parent_id)
        };
    }
    
    # Get children for this parent
    method _get_children ($db, $parent_id) {
        my $sql = q{
            SELECT fm.id, fm.child_name, fm.birth_date, fm.grade, fm.medical_info
            FROM family_members fm
            WHERE fm.family_id = ?
            ORDER BY fm.child_name
        };
        
        return $db->query($sql, $parent_id)->hashes->to_array;
    }
    
    # Get active enrollments with program details
    method _get_active_enrollments ($db, $parent_id) {
        my $sql = q{
            SELECT 
                e.id as enrollment_id,
                e.status as enrollment_status,
                e.created_at as enrolled_at,
                s.id as session_id,
                s.name as session_name,
                s.start_date,
                s.end_date,
                p.name as program_name,
                l.name as location_name,
                fm.child_name,
                COUNT(ev.id) as total_events,
                COUNT(ar.id) as attended_events
            FROM enrollments e
            JOIN sessions s ON e.session_id = s.id
            JOIN projects p ON s.project_id = p.id
            LEFT JOIN locations l ON s.location_id = l.id
            JOIN family_members fm ON e.family_member_id = fm.id
            LEFT JOIN events ev ON ev.session_id = s.id
            LEFT JOIN attendance_records ar ON ar.event_id = ev.id 
                AND ar.student_id = e.family_member_id 
                AND ar.status = 'present'
            WHERE fm.family_id = ? 
            AND e.status IN ('active', 'pending')
            GROUP BY e.id, s.id, p.id, l.id, fm.id
            ORDER BY s.start_date ASC
        };
        
        return $db->query($sql, $parent_id)->hashes->to_array;
    }
    
    # Get upcoming events for enrolled children
    method _get_upcoming_events ($db, $parent_id, $days = 7) {
        my $end_date = DateTime->now->add(days => $days)->epoch;
        
        my $sql = q{
            SELECT 
                ev.id as event_id,
                ev.name as event_name,
                ev.start_time,
                ev.end_time,
                s.name as session_name,
                l.name as location_name,
                l.address as location_address,
                fm.child_name,
                ar.status as attendance_status
            FROM events ev
            JOIN sessions s ON ev.session_id = s.id
            JOIN enrollments e ON e.session_id = s.id
            JOIN family_members fm ON e.family_member_id = fm.id
            LEFT JOIN locations l ON ev.location_id = l.id
            LEFT JOIN attendance_records ar ON ar.event_id = ev.id 
                AND ar.student_id = e.family_member_id
            WHERE fm.family_id = ?
            AND e.status IN ('active', 'pending')
            AND ev.start_time >= ?
            AND ev.start_time <= ?
            ORDER BY ev.start_time ASC
        };
        
        return $db->query($sql, $parent_id, time(), $end_date)->hashes->to_array;
    }
    
    # Get recent attendance records
    method _get_recent_attendance ($db, $parent_id, $limit = 10) {
        my $sql = q{
            SELECT 
                ar.id,
                ar.status,
                ar.marked_at,
                ev.name as event_name,
                ev.start_time as event_time,
                s.name as session_name,
                fm.child_name
            FROM attendance_records ar
            JOIN events ev ON ar.event_id = ev.id
            JOIN sessions s ON ev.session_id = s.id
            JOIN family_members fm ON ar.student_id = fm.id
            WHERE fm.family_id = ?
            ORDER BY ar.marked_at DESC
            LIMIT ?
        };
        
        return $db->query($sql, $parent_id, $limit)->hashes->to_array;
    }
    
    # Get recent messages
    method _get_recent_messages ($db, $parent_id, $limit = 5) {
        require Registry::DAO::Message;
        return Registry::DAO::Message->get_messages_for_parent(
            $db, $parent_id, limit => $limit
        );
    }
    
    # Get waitlist entries
    method _get_waitlist_entries ($db, $parent_id) {
        my $sql = q{
            SELECT 
                w.id,
                w.position,
                w.status,
                w.offered_at,
                w.expires_at,
                w.created_at,
                s.name as session_name,
                l.name as location_name,
                fm.child_name
            FROM waitlist w
            JOIN sessions s ON w.session_id = s.id
            LEFT JOIN locations l ON w.location_id = l.id
            JOIN family_members fm ON w.student_id = fm.id
            WHERE w.parent_id = ?
            AND w.status IN ('waiting', 'offered')
            ORDER BY w.created_at DESC
        };
        
        return $db->query($sql, $parent_id)->hashes->to_array;
    }
    
    # Get unread message count
    method _get_unread_message_count ($db, $parent_id) {
        require Registry::DAO::Message;
        return Registry::DAO::Message->get_unread_count($db, $parent_id);
    }
    
    # Get dashboard statistics
    method _get_dashboard_stats ($db, $parent_id) {
        # Active enrollments count
        my $active_enrollments = $db->select('enrollments e', 'COUNT(*)', {
            'e.family_member_id' => [
                -in => $db->select('family_members', 'id', { family_id => $parent_id })
            ],
            'e.status' => ['active', 'pending']
        })->array->[0] || 0;
        
        # Waitlist entries count
        my $waitlist_count = $db->select('waitlist', 'COUNT(*)', {
            parent_id => $parent_id,
            status => ['waiting', 'offered']
        })->array->[0] || 0;
        
        # This month's attendance rate
        my $month_start = DateTime->now->truncate(to => 'month')->epoch;
        my $attendance_sql = q{
            SELECT 
                COUNT(CASE WHEN ar.status = 'present' THEN 1 END) as present_count,
                COUNT(ar.id) as total_count
            FROM attendance_records ar
            JOIN events ev ON ar.event_id = ev.id
            JOIN family_members fm ON ar.student_id = fm.id
            WHERE fm.family_id = ?
            AND ar.marked_at >= ?
        };
        
        my $attendance_data = $db->query($attendance_sql, $parent_id, $month_start)->hash;
        my $attendance_rate = 0;
        if ($attendance_data && $attendance_data->{total_count} > 0) {
            $attendance_rate = sprintf("%.0f", 
                ($attendance_data->{present_count} / $attendance_data->{total_count}) * 100
            );
        }
        
        return {
            active_enrollments => $active_enrollments,
            waitlist_count => $waitlist_count,
            attendance_rate => $attendance_rate
        };
    }
}