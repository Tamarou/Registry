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
        
        my $dao = $c->dao($c->stash('tenant'));
        
        # Get all dashboard data
        require Registry::DAO::AdminDashboard;
        my $dashboard_data = Registry::DAO::AdminDashboard->get_admin_dashboard_data($dao->db, $user);
        
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
        
        my $dao = $c->dao($c->stash('tenant'));
        my $time_range = $c->param('range') || 'current'; # current, upcoming, all
        
        require Registry::DAO::Program;
        my $programs = Registry::DAO::Program->get_program_overview($dao->db, $time_range);
        
        $c->stash(programs => $programs, time_range => $time_range);
        $c->render(template => 'admin_dashboard/program_overview', layout => undef);
    }
    
    # Today's events with attendance (HTMX endpoint)
    method todays_events ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden') 
            unless $user->{role} =~ /^(admin|staff|instructor)$/;
        
        my $dao = $c->dao($c->stash('tenant'));
        my $date = $c->param('date') || DateTime->now->ymd; # YYYY-MM-DD format
        
        require Registry::DAO::Event;
        my $events = Registry::DAO::Event->get_events_for_date($dao->db, $date);
        
        $c->stash(events => $events, selected_date => $date);
        $c->render(template => 'admin_dashboard/todays_events', layout => undef);
    }
    
    # Waitlist management data (HTMX endpoint)
    method waitlist_management ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden') 
            unless $user->{role} =~ /^(admin|staff|instructor)$/;
        
        my $dao = $c->dao($c->stash('tenant'));
        my $status_filter = $c->param('status') || 'all'; # all, waiting, offered, urgent
        
        require Registry::DAO::Waitlist;
        my $waitlist_data = Registry::DAO::Waitlist->get_waitlist_management_data($dao->db, $status_filter);
        
        $c->stash(waitlist_data => $waitlist_data, status_filter => $status_filter);
        $c->render(template => 'admin_dashboard/waitlist_management', layout => undef);
    }
    
    # Recent notifications (HTMX endpoint)  
    method recent_notifications ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden') 
            unless $user->{role} =~ /^(admin|staff|instructor)$/;
        
        my $dao = $c->dao($c->stash('tenant'));
        my $limit = $c->param('limit') || 10;
        my $type_filter = $c->param('type') || 'all'; # all, attendance, waitlist, message
        
        require Registry::DAO::Notification;
        my $notifications = Registry::DAO::Notification->get_recent_for_admin($dao->db, $limit, $type_filter);
        
        $c->stash(notifications => $notifications, type_filter => $type_filter);
        $c->render(template => 'admin_dashboard/recent_notifications', layout => undef);
    }
    
    # Enrollment trends data for charts (JSON endpoint)
    method enrollment_trends ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden') 
            unless $user->{role} =~ /^(admin|staff|instructor)$/;
        
        my $dao = $c->dao($c->stash('tenant'));
        my $period = $c->param('period') || 'month'; # week, month, quarter
        
        require Registry::DAO::AdminDashboard;
        my $trends_data = Registry::DAO::AdminDashboard->get_enrollment_trends($dao->db, $period);
        
        $c->render(json => $trends_data);
    }
    
    # Export data
    method export_data ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden') 
            unless $user->{role} =~ /^(admin|staff)$/; # More restrictive for exports
        
        my $dao = $c->dao($c->stash('tenant'));
        my $export_type = $c->param('type') || 'enrollments'; # enrollments, attendance, waitlist
        my $format = $c->param('format') || 'csv'; # csv, json
        
        try {
            require Registry::DAO::AdminDashboard;
            my $data = Registry::DAO::AdminDashboard->get_export_data($dao->db, $export_type);

            # Determine if we should use streaming based on data size
            my $record_count = @$data;
            my $use_streaming = $record_count > 1000; # Stream for datasets > 1000 records

            # Set content disposition header for downloads
            $c->res->headers->content_disposition("attachment; filename=\"${export_type}.${format}\"");

            # For streaming large datasets, set appropriate headers
            if ($use_streaming && $format eq 'csv') {
                $c->res->headers->content_type('text/csv; charset=utf-8');
                $c->res->headers->transfer_encoding('chunked');
            }

            # Use format-based rendering with streaming support
            $c->respond_to(
                json => { json => $data },
                csv  => {
                    csv => $data,
                    stream => $use_streaming,
                    chunk_size => 500  # Process 500 records per chunk
                },
                any  => {
                    csv => $data,
                    stream => $use_streaming,
                    chunk_size => 500
                }
            );
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

        my $dao = $c->dao($c->stash('tenant'));
        my $status_filter = $c->param('status') || 'pending'; # pending, approved, denied, all

        my $drop_requests = Registry::DAO::DropRequest->get_detailed_requests($dao->db, $status_filter);

        $c->stash(drop_requests => $drop_requests, status_filter => $status_filter);
        $c->render(template => 'admin_dashboard/pending_drop_requests', layout => undef);
    }

    # Get pending transfer requests (HTMX endpoint)
    method pending_transfer_requests ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden')
            unless $user->{role} =~ /^(admin|staff)$/;

        my $dao = $c->dao($c->stash('tenant'));
        my $status_filter = $c->param('status') || 'pending';

        my $transfer_requests = Registry::DAO::TransferRequest->get_detailed_requests($dao->db, $status_filter);

        $c->stash(transfer_requests => $transfer_requests, status_filter => $status_filter);
        $c->render(template => 'admin_dashboard/pending_transfer_requests', layout => undef);
    }


    # Quick action: Send bulk message
    method send_bulk_message ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden') 
            unless $user->{role} =~ /^(admin|staff|instructor)$/;
        
        my $dao = $c->dao($c->stash('tenant'));
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
            my $recipients = Registry::DAO::Message->get_recipients_for_scope($dao->db, $scope, $scope_id);
            
            unless (@$recipients) {
                return $c->render(json => { error => 'No recipients found for selected scope' }, status => 400);
            }
            
            my @recipient_ids = map { $_->{id} } @$recipients;
            
            # Send message
            my $sent_message = Registry::DAO::Message->send_message($dao->db, {
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


}