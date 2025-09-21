# ABOUTME: AdminDashboard DAO for aggregating administrative dashboard data and statistics
# ABOUTME: Provides methods for overview stats, alerts, and administrative data aggregation
use 5.40.2;
use Object::Pad;

class Registry::DAO::AdminDashboard :isa(Registry::DAO::Object) {
    use DateTime;

    sub table { 'admin_dashboard' } # This DAO doesn't map to a single table

    # Get overview statistics for admin dashboard
    sub get_overview_stats($class, $db) {
        # Total active enrollments
        my $active_enrollments = $db->select('enrollments', 'COUNT(*)', {
            status => ['active', 'pending']
        })->array->[0] || 0;

        # Total programs
        my $active_programs = $db->select('projects', 'COUNT(*)', {
            status => 'active'
        })->array->[0] || 0;

        # Total waitlist entries
        my $waitlist_entries = $db->select('waitlist', 'COUNT(*)', {
            status => ['waiting', 'offered']
        })->array->[0] || 0;

        # Today's events
        my $today_start = DateTime->now->truncate(to => 'day')->epoch;
        my $today_end = DateTime->now->truncate(to => 'day')->add(days => 1)->epoch;

        my $todays_events = $db->select('events', 'COUNT(*)', {
            start_time => { '>=' => $today_start, '<' => $today_end }
        })->array->[0] || 0;

        # This month's revenue (if payment tracking is available)
        my $month_start = DateTime->now->truncate(to => 'month')->epoch;
        my $monthly_revenue = $db->select('payments', 'SUM(amount)', {
            status => 'completed',
            created_at => { '>=' => $month_start }
        })->array->[0] || 0;

        # Pending drop requests
        my $pending_drop_requests = $db->select('drop_requests', 'COUNT(*)', {
            status => 'pending'
        })->array->[0] || 0;

        # Pending transfer requests
        my $pending_transfer_requests = $db->select('transfer_requests', 'COUNT(*)', {
            status => 'pending'
        })->array->[0] || 0;

        return {
            active_enrollments => $active_enrollments,
            active_programs => $active_programs,
            waitlist_entries => $waitlist_entries,
            todays_events => $todays_events,
            monthly_revenue => sprintf("%.2f", $monthly_revenue / 100), # Convert cents to dollars
            pending_drop_requests => $pending_drop_requests,
            pending_transfer_requests => $pending_transfer_requests
        };
    }

    # Get enrollment alerts (high capacity utilization)
    sub get_enrollment_alerts($class, $db) {
        my $sql = q{
            SELECT
                p.name as program_name,
                s.name as session_name,
                COUNT(DISTINCT e.id) as enrolled_count,
                ev.capacity,
                (COUNT(DISTINCT e.id)::float / ev.capacity * 100) as utilization_rate
            FROM sessions s
            JOIN projects p ON s.project_id = p.id
            JOIN enrollments e ON s.id = e.session_id AND e.status = 'active'
            JOIN events ev ON s.id = ev.session_id
            WHERE s.start_date > ?
            GROUP BY p.id, s.id, ev.capacity
            HAVING COUNT(DISTINCT e.id)::float / ev.capacity > 0.9
            ORDER BY utilization_rate DESC
            LIMIT 5
        };

        return $db->query($sql, time())->hashes->to_array;
    }

    # Get waitlist summary for admin dashboard
    sub get_waitlist_summary($class, $db) {
        my $sql = q{
            SELECT
                s.name as session_name,
                COUNT(w.id) as total_waiting,
                COUNT(CASE WHEN w.status = 'offered' THEN 1 END) as offers_pending,
                COUNT(CASE WHEN w.status = 'offered' AND w.expires_at < ? THEN 1 END) as expiring_soon
            FROM waitlist w
            JOIN sessions s ON w.session_id = s.id
            WHERE w.status IN ('waiting', 'offered')
            GROUP BY s.id, s.name
            HAVING COUNT(w.id) > 0
            ORDER BY total_waiting DESC
            LIMIT 10
        };

        return $db->query($sql, time() + 86400)->hashes->to_array;
    }

    # Get enrollment trends for charts
    sub get_enrollment_trends($class, $db, $period) {
        my ($interval, $format, $start_date);

        if ($period eq 'week') {
            $interval = '1 day';
            $format = 'YYYY-MM-DD';
            $start_date = DateTime->now->subtract(weeks => 2);
        } elsif ($period eq 'quarter') {
            $interval = '1 week';
            $format = 'YYYY-"W"WW';
            $start_date = DateTime->now->subtract(months => 3);
        } else { # month
            $interval = '1 week';
            $format = 'YYYY-"W"WW';
            $start_date = DateTime->now->subtract(months => 1);
        }

        my $sql = qq{
            SELECT
                TO_CHAR(DATE_TRUNC('day', TO_TIMESTAMP(e.created_at)), '$format') as period,
                COUNT(*) as enrollments
            FROM enrollments e
            WHERE e.created_at >= ?
            GROUP BY period
            ORDER BY period
        };

        my $results = $db->query($sql, $start_date->epoch)->hashes->to_array;

        return {
            labels => [map { $_->{period} } @$results],
            data => [map { $_->{enrollments} } @$results],
            period => $period
        };
    }

    # Get complete admin dashboard data
    sub get_admin_dashboard_data($class, $db, $user) {
        return {
            overview_stats => $class->get_overview_stats($db),
            program_summary => Registry::DAO::Project->get_program_overview($db, 'current'),
            todays_events => Registry::DAO::Event->get_events_for_date($db, DateTime->now->ymd),
            recent_notifications => Registry::DAO::Notification->get_recent_for_admin($db, 5, 'all'),
            waitlist_summary => $class->get_waitlist_summary($db),
            enrollment_alerts => $class->get_enrollment_alerts($db),
            pending_drop_requests => Registry::DAO::DropRequest->get_detailed_requests($db, 'pending', 10),
            pending_transfer_requests => Registry::DAO::TransferRequest->get_detailed_requests($db, 'pending')
        };
    }

    # Get export data for admin dashboard
    sub get_export_data($class, $db, $export_type) {
        if ($export_type eq 'enrollments') {
            return $db->query(q{
                SELECT
                    e.id as enrollment_id,
                    e.status,
                    e.created_at,
                    fm.child_name,
                    up.name as parent_name,
                    up.email as parent_email,
                    s.name as session_name,
                    p.name as program_name,
                    l.name as location_name
                FROM enrollments e
                JOIN family_members fm ON e.family_member_id = fm.id
                JOIN user_profiles up ON fm.family_id = up.user_id
                JOIN sessions s ON e.session_id = s.id
                JOIN projects p ON s.project_id = p.id
                LEFT JOIN locations l ON s.location_id = l.id
                ORDER BY e.created_at DESC
            })->hashes->to_array;
        } elsif ($export_type eq 'attendance') {
            return $db->query(q{
                SELECT
                    ar.id,
                    ar.status,
                    ar.marked_at,
                    ev.name as event_name,
                    ev.start_time,
                    s.name as session_name,
                    fm.child_name,
                    up.name as parent_name
                FROM attendance_records ar
                JOIN events ev ON ar.event_id = ev.id
                JOIN sessions s ON ev.session_id = s.id
                JOIN family_members fm ON ar.student_id = fm.id
                JOIN user_profiles up ON fm.family_id = up.user_id
                ORDER BY ar.marked_at DESC
            })->hashes->to_array;
        } elsif ($export_type eq 'waitlist') {
            return $db->query(q{
                SELECT
                    w.id,
                    w.position,
                    w.status,
                    w.offered_at,
                    w.expires_at,
                    w.created_at,
                    fm.child_name,
                    up.name as parent_name,
                    up.email as parent_email,
                    s.name as session_name,
                    p.name as program_name
                FROM waitlist w
                JOIN family_members fm ON w.student_id = fm.id
                JOIN user_profiles up ON w.parent_id = up.user_id
                JOIN sessions s ON w.session_id = s.id
                JOIN projects p ON s.project_id = p.id
                ORDER BY w.created_at DESC
            })->hashes->to_array;
        }

        return [];
    }
}

1;