use 5.40.2;
use utf8;
use experimental qw(signatures try);
use Object::Pad;

class Registry::Controller::AdminDashboard :isa(Registry::Controller) {
    use DateTime;
    use List::Util qw(sum max);
    use JSON qw(encode_json);
    
    # Main admin dashboard
    method index ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden') 
            unless $user->{role} =~ /^(admin|staff|instructor)$/;
        
        my $db = $c->app->db($c->stash('tenant'));
        
        # Get all dashboard data
        my $dashboard_data = $self->_get_admin_dashboard_data($db, $user);
        
        # Pass data to template
        $c->stash(%$dashboard_data);
        $c->render(template => 'admin_dashboard/index');
    }
    
    # Program overview data (HTMX endpoint)
    method program_overview ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden') 
            unless $user->{role} =~ /^(admin|staff|instructor)$/;
        
        my $db = $c->app->db($c->stash('tenant'));
        my $time_range = $c->param('range') || 'current'; # current, upcoming, all
        
        my $programs = $self->_get_program_overview($db, $time_range);
        
        $c->stash(programs => $programs, time_range => $time_range);
        $c->render(template => 'admin_dashboard/program_overview', layout => undef);
    }
    
    # Today's events with attendance (HTMX endpoint)
    method todays_events ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden') 
            unless $user->{role} =~ /^(admin|staff|instructor)$/;
        
        my $db = $c->app->db($c->stash('tenant'));
        my $date = $c->param('date') || DateTime->now->ymd; # YYYY-MM-DD format
        
        my $events = $self->_get_events_for_date($db, $date);
        
        $c->stash(events => $events, selected_date => $date);
        $c->render(template => 'admin_dashboard/todays_events', layout => undef);
    }
    
    # Waitlist management data (HTMX endpoint)
    method waitlist_management ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden') 
            unless $user->{role} =~ /^(admin|staff|instructor)$/;
        
        my $db = $c->app->db($c->stash('tenant'));
        my $status_filter = $c->param('status') || 'all'; # all, waiting, offered, urgent
        
        my $waitlist_data = $self->_get_waitlist_management_data($db, $status_filter);
        
        $c->stash(waitlist_data => $waitlist_data, status_filter => $status_filter);
        $c->render(template => 'admin_dashboard/waitlist_management', layout => undef);
    }
    
    # Recent notifications (HTMX endpoint)  
    method recent_notifications ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden') 
            unless $user->{role} =~ /^(admin|staff|instructor)$/;
        
        my $db = $c->app->db($c->stash('tenant'));
        my $limit = $c->param('limit') || 10;
        my $type_filter = $c->param('type') || 'all'; # all, attendance, waitlist, message
        
        my $notifications = $self->_get_recent_notifications($db, $limit, $type_filter);
        
        $c->stash(notifications => $notifications, type_filter => $type_filter);
        $c->render(template => 'admin_dashboard/recent_notifications', layout => undef);
    }
    
    # Enrollment trends data for charts (JSON endpoint)
    method enrollment_trends ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden') 
            unless $user->{role} =~ /^(admin|staff|instructor)$/;
        
        my $db = $c->app->db($c->stash('tenant'));
        my $period = $c->param('period') || 'month'; # week, month, quarter
        
        my $trends_data = $self->_get_enrollment_trends($db, $period);
        
        $c->render(json => $trends_data);
    }
    
    # Export data
    method export_data ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden') 
            unless $user->{role} =~ /^(admin|staff)$/; # More restrictive for exports
        
        my $db = $c->app->db($c->stash('tenant'));
        my $export_type = $c->param('type') || 'enrollments'; # enrollments, attendance, waitlist
        my $format = $c->param('format') || 'csv'; # csv, json
        
        try {
            my $data = $self->_get_export_data($db, $export_type);
            
            if ($format eq 'json') {
                $c->res->headers->content_type('application/json');
                $c->res->headers->content_disposition("attachment; filename=\"${export_type}.json\"");
                return $c->render(json => $data);
            } else {
                # CSV format
                my $csv_content = $self->_convert_to_csv($data, $export_type);
                $c->res->headers->content_type('text/csv');
                $c->res->headers->content_disposition("attachment; filename=\"${export_type}.csv\"");
                return $c->render(data => $csv_content);
            }
        }
        catch ($e) {
            $c->flash(error => "Export failed: $e");
            return $c->redirect_to('admin_dashboard');
        }
    }
    
    # Drop request management (HTMX endpoint)
    method pending_drop_requests ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden')
            unless $user->{role} =~ /^(admin|staff)$/;

        my $db = $c->app->db($c->stash('tenant'));
        my $status_filter = $c->param('status') || 'pending'; # pending, approved, denied, all

        my $drop_requests = $self->_get_drop_requests($db, $status_filter);

        $c->stash(drop_requests => $drop_requests, status_filter => $status_filter);
        $c->render(template => 'admin_dashboard/pending_drop_requests', layout => undef);
    }

    # Get pending transfer requests (HTMX endpoint)
    method pending_transfer_requests ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden')
            unless $user->{role} =~ /^(admin|staff)$/;

        my $db = $c->app->db($c->stash('tenant'));
        my $status_filter = $c->param('status') || 'pending';

        my $transfer_requests = $self->_get_transfer_requests($db, $status_filter);

        $c->stash(transfer_requests => $transfer_requests, status_filter => $status_filter);
        $c->render(template => 'admin_dashboard/pending_transfer_requests', layout => undef);
    }

    # Process transfer request (approve/deny)
    method process_transfer_request ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden')
            unless $user->{role} =~ /^(admin|staff)$/;

        my $transfer_request_id = $c->param('transfer_request_id');
        my $action = $c->param('action'); # 'approve' or 'deny'
        my $admin_notes = $c->param('admin_notes') || '';

        my $db = $c->app->db($c->stash('tenant'));

        try {
            my $transfer_request = Registry::DAO::TransferRequest->find($db, { id => $transfer_request_id });
            return $c->render(status => 404, text => 'Transfer request not found') unless $transfer_request;

            if ($action eq 'approve') {
                $transfer_request->approve($db, $user, $admin_notes);

                if ($c->accepts('', 'html')) {
                    $c->flash(success => 'Transfer request approved and processed successfully.');
                    return $c->redirect_to('admin_dashboard');
                } else {
                    return $c->render(json => {
                        success => 1,
                        message => 'Transfer request approved and processed',
                        action => 'approved'
                    });
                }
            } elsif ($action eq 'deny') {
                $transfer_request->deny($db, $user, $admin_notes);

                if ($c->accepts('', 'html')) {
                    $c->flash(info => 'Transfer request denied.');
                    return $c->redirect_to('admin_dashboard');
                } else {
                    return $c->render(json => {
                        success => 1,
                        message => 'Transfer request denied',
                        action => 'denied'
                    });
                }
            } else {
                return $c->render(status => 400, text => 'Invalid action specified');
            }
        }
        catch ($e) {
            if ($c->accepts('', 'html')) {
                $c->flash(error => "Failed to process transfer request: $e");
                return $c->redirect_to('admin_dashboard');
            } else {
                return $c->render(json => { error => "Failed to process transfer request: $e" }, status => 500);
            }
        }
    }

    # Process drop request (approve/deny)
    method process_drop_request ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden')
            unless $user->{role} =~ /^(admin|staff)$/;

        my $request_id = $c->param('request_id');
        my $action = $c->param('action'); # approve, deny
        my $admin_notes = $c->param('admin_notes') || '';
        my $refund_amount = $c->param('refund_amount');
        my $db = $c->app->db($c->stash('tenant'));

        unless ($request_id && $action && ($action eq 'approve' || $action eq 'deny')) {
            return $c->render(json => { error => 'Request ID and valid action required' }, status => 400);
        }

        try {
            # Find the drop request
            my $drop_request = Registry::DAO::DropRequest->find($db, { id => $request_id });
            return $c->render(json => { error => 'Drop request not found' }, status => 404) unless $drop_request;

            if ($drop_request->status ne 'pending') {
                return $c->render(json => { error => 'Drop request has already been processed' }, status => 400);
            }

            if ($action eq 'approve') {
                $drop_request->approve($db, $user, $admin_notes, $refund_amount);

                # Notify parent of approval
                $c->app->minion->enqueue('notify_drop_request_approved', [$drop_request->id], {
                    attempts => 3,
                    priority => 6
                });

                if ($c->accepts('', 'html')) {
                    $c->flash(success => 'Drop request approved successfully. Parent will be notified.');
                    return $c->redirect_to('admin_dashboard');
                } else {
                    return $c->render(json => {
                        success => 1,
                        message => 'Drop request approved',
                        status => 'approved'
                    });
                }
            } else { # deny
                $drop_request->deny($db, $user, $admin_notes);

                # Notify parent of denial
                $c->app->minion->enqueue('notify_drop_request_denied', [$drop_request->id], {
                    attempts => 3,
                    priority => 6
                });

                if ($c->accepts('', 'html')) {
                    $c->flash(success => 'Drop request denied. Parent will be notified.');
                    return $c->redirect_to('admin_dashboard');
                } else {
                    return $c->render(json => {
                        success => 1,
                        message => 'Drop request denied',
                        status => 'denied'
                    });
                }
            }
        }
        catch ($e) {
            if ($c->accepts('', 'html')) {
                $c->flash(error => "Failed to process drop request: $e");
                return $c->redirect_to('admin_dashboard');
            } else {
                return $c->render(json => { error => "Failed to process drop request: $e" }, status => 500);
            }
        }
    }

    # Quick action: Send bulk message
    method send_bulk_message ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden') 
            unless $user->{role} =~ /^(admin|staff|instructor)$/;
        
        my $db = $c->app->db($c->stash('tenant'));
        my $recipient_scope = $c->param('scope'); # program_id, session_id, tenant-wide
        my $subject = $c->param('subject');
        my $message = $c->param('message');
        my $message_type = $c->param('message_type') || 'announcement';
        
        unless ($subject && $message && $recipient_scope) {
            return $c->render(json => { error => 'Subject, message, and scope are required' }, status => 400);
        }
        
        try {
            require Registry::DAO::Message;
            
            # Determine scope and scope_id
            my ($scope, $scope_id) = $self->_parse_recipient_scope($recipient_scope);
            
            # Get recipients
            my $recipients = Registry::DAO::Message->get_recipients_for_scope($db, $scope, $scope_id);
            
            unless (@$recipients) {
                return $c->render(json => { error => 'No recipients found for selected scope' }, status => 400);
            }
            
            my @recipient_ids = map { $_->{id} } @$recipients;
            
            # Send message
            my $sent_message = Registry::DAO::Message->send_message($db, {
                sender_id => $user->{id},
                subject => $subject,
                body => $message,
                message_type => $message_type,
                scope => $scope,
                scope_id => $scope_id
            }, \@recipient_ids, send_now => 1);
            
            return $c->render(json => {
                success => 1,
                message_id => $sent_message->id,
                recipients_count => scalar(@recipient_ids)
            });
        }
        catch ($e) {
            return $c->render(json => { error => "Failed to send message: $e" }, status => 500);
        }
    }
    
    # Private helper methods
    
    # Get all admin dashboard data
    method _get_admin_dashboard_data ($db, $user) {
        return {
            overview_stats => $self->_get_overview_stats($db),
            program_summary => $self->_get_program_overview($db, 'current'),
            todays_events => $self->_get_events_for_date($db, DateTime->now->ymd),
            recent_notifications => $self->_get_recent_notifications($db, 5, 'all'),
            waitlist_summary => $self->_get_waitlist_summary($db),
            enrollment_alerts => $self->_get_enrollment_alerts($db),
            pending_drop_requests => $self->_get_drop_requests($db, 'pending', 10),
            pending_transfer_requests => $self->_get_transfer_requests($db, 'pending', 10)
        };
    }
    
    # Get overview statistics
    method _get_overview_stats ($db) {
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
    
    # Get program overview with enrollment and capacity data
    method _get_program_overview ($db, $time_range) {
        my $sql = q{
            SELECT 
                p.id as program_id,
                p.name as program_name,
                p.status as program_status,
                COUNT(DISTINCT s.id) as session_count,
                COUNT(DISTINCT e.id) as total_enrollments,
                COUNT(DISTINCT CASE WHEN e.status = 'active' THEN e.id END) as active_enrollments,
                COUNT(DISTINCT w.id) as waitlist_count,
                SUM(ev.capacity) as total_capacity,
                MIN(s.start_date) as earliest_start,
                MAX(s.end_date) as latest_end
            FROM projects p
            LEFT JOIN sessions s ON p.id = s.project_id
            LEFT JOIN enrollments e ON s.id = e.session_id
            LEFT JOIN waitlist w ON s.id = w.session_id AND w.status IN ('waiting', 'offered')
            LEFT JOIN events ev ON s.id = ev.session_id
        };
        
        my @where_conditions;
        my @params;
        
        if ($time_range eq 'current') {
            push @where_conditions, 's.start_date <= ? AND s.end_date >= ?';
            my $now = time();
            push @params, $now, $now;
        } elsif ($time_range eq 'upcoming') {
            push @where_conditions, 's.start_date > ?';
            push @params, time();
        }
        
        if (@where_conditions) {
            $sql .= ' WHERE ' . join(' AND ', @where_conditions);
        }
        
        $sql .= q{
            GROUP BY p.id, p.name, p.status
            ORDER BY p.name
        };
        
        my $results = $db->query($sql, @params)->hashes->to_array;
        
        # Calculate utilization rates
        for my $program (@$results) {
            if ($program->{total_capacity} && $program->{total_capacity} > 0) {
                $program->{utilization_rate} = sprintf("%.0f", 
                    ($program->{active_enrollments} / $program->{total_capacity}) * 100
                );
            } else {
                $program->{utilization_rate} = 0;
            }
        }
        
        return $results;
    }
    
    # Get events for a specific date with attendance status
    method _get_events_for_date ($db, $date) {
        my $date_obj = DateTime->from_ymd(split /-/, $date);
        my $start_time = $date_obj->epoch;
        my $end_time = $date_obj->add(days => 1)->epoch;
        
        my $sql = q{
            SELECT 
                ev.id as event_id,
                ev.name as event_name,
                ev.start_time,
                ev.end_time,
                ev.capacity,
                s.name as session_name,
                p.name as program_name,
                l.name as location_name,
                COUNT(DISTINCT e.id) as enrolled_count,
                COUNT(DISTINCT ar.id) as attendance_taken,
                COUNT(DISTINCT CASE WHEN ar.status = 'present' THEN ar.id END) as present_count,
                COUNT(DISTINCT CASE WHEN ar.status = 'absent' THEN ar.id END) as absent_count
            FROM events ev
            JOIN sessions s ON ev.session_id = s.id
            JOIN projects p ON s.project_id = p.id
            LEFT JOIN locations l ON ev.location_id = l.id
            LEFT JOIN enrollments e ON s.id = e.session_id AND e.status = 'active'
            LEFT JOIN attendance_records ar ON ev.id = ar.event_id
            WHERE ev.start_time >= ? AND ev.start_time < ?
            GROUP BY ev.id, s.id, p.id, l.id
            ORDER BY ev.start_time ASC
        };
        
        my $results = $db->query($sql, $start_time, $end_time)->hashes->to_array;
        
        # Add attendance status
        for my $event (@$results) {
            if ($event->{attendance_taken} > 0) {
                $event->{attendance_status} = 'completed';
            } elsif ($event->{start_time} < time()) {
                $event->{attendance_status} = 'missing';
            } else {
                $event->{attendance_status} = 'pending';
            }
        }
        
        return $results;
    }
    
    # Get waitlist management data
    method _get_waitlist_management_data ($db, $status_filter) {
        my $sql = q{
            SELECT 
                w.id,
                w.position,
                w.status,
                w.offered_at,
                w.expires_at,
                w.created_at,
                s.name as session_name,
                p.name as program_name,
                l.name as location_name,
                fm.child_name,
                up.name as parent_name,
                up.email as parent_email
            FROM waitlist w
            JOIN sessions s ON w.session_id = s.id
            JOIN projects p ON s.project_id = p.id
            LEFT JOIN locations l ON w.location_id = l.id
            LEFT JOIN family_members fm ON w.student_id = fm.id
            LEFT JOIN user_profiles up ON w.parent_id = up.user_id
        };
        
        my @where_conditions;
        my @params;
        
        if ($status_filter eq 'waiting') {
            push @where_conditions, "w.status = 'waiting'";
        } elsif ($status_filter eq 'offered') {
            push @where_conditions, "w.status = 'offered'";
        } elsif ($status_filter eq 'urgent') {
            push @where_conditions, "w.status = 'offered' AND w.expires_at < ?";
            push @params, time() + 86400; # Expiring within 24 hours
        } elsif ($status_filter ne 'all') {
            push @where_conditions, "w.status IN ('waiting', 'offered')";
        }
        
        if (@where_conditions) {
            $sql .= ' WHERE ' . join(' AND ', @where_conditions);
        }
        
        $sql .= ' ORDER BY w.created_at DESC LIMIT 50';
        
        return $db->query($sql, @params)->hashes->to_array;
    }
    
    # Get recent notifications
    method _get_recent_notifications ($db, $limit, $type_filter) {
        my $sql = q{
            SELECT 
                n.id,
                n.type,
                n.channel,
                n.subject,
                n.message,
                n.sent_at,
                n.delivered_at,
                n.metadata,
                up.name as recipient_name,
                up.email as recipient_email
            FROM notifications n
            LEFT JOIN user_profiles up ON n.user_id = up.user_id
        };
        
        my @where_conditions;
        my @params;
        
        if ($type_filter eq 'attendance') {
            push @where_conditions, "n.type LIKE 'attendance%'";
        } elsif ($type_filter eq 'waitlist') {
            push @where_conditions, "n.type LIKE 'waitlist%'";
        } elsif ($type_filter eq 'message') {
            push @where_conditions, "n.type LIKE 'message%'";
        }
        
        if (@where_conditions) {
            $sql .= ' WHERE ' . join(' AND ', @where_conditions);
        }
        
        $sql .= ' ORDER BY n.created_at DESC LIMIT ?';
        push @params, $limit;
        
        return $db->query($sql, @params)->hashes->to_array;
    }
    
    # Get waitlist summary
    method _get_waitlist_summary ($db) {
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
    
    # Get enrollment alerts
    method _get_enrollment_alerts ($db) {
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
    
    # Get enrollment trends for charts
    method _get_enrollment_trends ($db, $period) {
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
    
    # Get export data
    method _get_export_data ($db, $export_type) {
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
    
    # Convert data to CSV format
    method _convert_to_csv ($data, $export_type) {
        return '' unless @$data;
        
        my @headers = keys %{$data->[0]};
        my $csv = join(',', map { qq("$_") } @headers) . "\n";
        
        for my $row (@$data) {
            my @values = map { 
                my $val = $row->{$_} // '';
                $val =~ s/"/""/g; # Escape quotes
                qq("$val");
            } @headers;
            $csv .= join(',', @values) . "\n";
        }
        
        return $csv;
    }
    
    # Parse recipient scope for bulk messaging
    method _parse_recipient_scope ($scope_param) {
        if ($scope_param eq 'tenant-wide') {
            return ('tenant-wide', undef);
        } elsif ($scope_param =~ /^program_(\d+)$/) {
            return ('program', $1);
        } elsif ($scope_param =~ /^session_(\d+)$/) {
            return ('session', $1);
        } elsif ($scope_param =~ /^location_(\d+)$/) {
            return ('location', $1);
        }

        return ('tenant-wide', undef); # Default fallback
    }

    # Get drop requests with enrollment and family details
    method _get_drop_requests ($db, $status_filter = 'pending', $limit = 50) {
        my $sql = q{
            SELECT
                dr.id,
                dr.enrollment_id,
                dr.requested_by,
                dr.reason,
                dr.refund_requested,
                dr.refund_amount_requested,
                dr.status,
                dr.admin_notes,
                dr.processed_by,
                dr.processed_at,
                dr.created_at,
                dr.updated_at,
                e.status as enrollment_status,
                s.name as session_name,
                s.start_date,
                s.end_date,
                p.name as program_name,
                l.name as location_name,
                fm.child_name,
                up_parent.name as parent_name,
                up_parent.email as parent_email,
                up_admin.name as admin_name
            FROM drop_requests dr
            JOIN enrollments e ON dr.enrollment_id = e.id
            JOIN sessions s ON e.session_id = s.id
            JOIN projects p ON s.project_id = p.id
            LEFT JOIN locations l ON s.location_id = l.id
            LEFT JOIN family_members fm ON e.family_member_id = fm.id
            LEFT JOIN user_profiles up_parent ON dr.requested_by = up_parent.user_id
            LEFT JOIN user_profiles up_admin ON dr.processed_by = up_admin.user_id
        };

        my @where_conditions;
        my @params;

        if ($status_filter eq 'pending') {
            push @where_conditions, "dr.status = 'pending'";
        } elsif ($status_filter eq 'approved') {
            push @where_conditions, "dr.status = 'approved'";
        } elsif ($status_filter eq 'denied') {
            push @where_conditions, "dr.status = 'denied'";
        } elsif ($status_filter ne 'all') {
            push @where_conditions, "dr.status = 'pending'"; # Default to pending
        }

        if (@where_conditions) {
            $sql .= ' WHERE ' . join(' AND ', @where_conditions);
        }

        $sql .= ' ORDER BY dr.created_at DESC';

        if ($limit) {
            $sql .= ' LIMIT ?';
            push @params, $limit;
        }

        my $results = $db->query($sql, @params)->hashes->to_array;

        # Add additional computed fields
        for my $request (@$results) {
            # Days since request
            my $created_time = $request->{created_at};
            if ($created_time) {
                my $days_ago = int((time() - $created_time) / 86400);
                $request->{days_since_request} = $days_ago;

                if ($days_ago == 0) {
                    $request->{urgency} = 'today';
                } elsif ($days_ago <= 2) {
                    $request->{urgency} = 'recent';
                } elsif ($days_ago <= 7) {
                    $request->{urgency} = 'normal';
                } else {
                    $request->{urgency} = 'old';
                }
            }

            # Session status relative to drop request
            if ($request->{start_date}) {
                my $session_start = $request->{start_date};
                if ($session_start =~ /^(\d{4})-(\d{2})-(\d{2})/) {
                    my $session_date = DateTime->new(year => $1, month => $2, day => $3);
                    my $now = DateTime->now;

                    if ($session_date > $now) {
                        $request->{session_status} = 'upcoming';
                    } elsif ($session_date->ymd eq $now->ymd) {
                        $request->{session_status} = 'today';
                    } else {
                        $request->{session_status} = 'ongoing';
                    }
                }
            }

            # Format refund amount for display
            if ($request->{refund_amount_requested}) {
                $request->{refund_amount_display} = sprintf('$%.2f', $request->{refund_amount_requested} / 100);
            }
        }

        return $results;
    }

    # Get transfer requests with enrollment and family details
    method _get_transfer_requests ($db, $status_filter = 'pending', $limit = 50) {
        require Registry::DAO::TransferRequest;
        return Registry::DAO::TransferRequest->get_detailed_requests($db, $status_filter);
    }
}