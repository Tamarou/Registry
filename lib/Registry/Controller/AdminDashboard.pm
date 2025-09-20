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
        
        require Registry::DAO::Project;
        my $programs = Registry::DAO::Project->get_program_overview($dao->db, $time_range);
        
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

            # Set content disposition header for downloads
            $c->res->headers->content_disposition("attachment; filename=\"${export_type}.${format}\"");

            # Use format-based rendering
            $c->respond_to(
                json => { json => $data },
                csv  => { csv => $data },
                any  => { csv => $data } # Default to CSV for unknown formats
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

    # Process transfer request (approve/deny)
    method process_transfer_request ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden')
            unless $user->{role} =~ /^(admin|staff)$/;

        my $transfer_request_id = $c->param('transfer_request_id');
        my $action = $c->param('action'); # 'approve' or 'deny'
        my $admin_notes = $c->param('admin_notes') || '';

        my $dao = $c->dao($c->stash('tenant'));

        try {
            my $transfer_request = Registry::DAO::TransferRequest->find($dao->db, { id => $transfer_request_id });
            return $c->render(status => 404, text => 'Transfer request not found') unless $transfer_request;

            if ($action eq 'approve') {
                $transfer_request->approve($dao->db, $user, $admin_notes);

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
                $transfer_request->deny($dao->db, $user, $admin_notes);

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
        my $dao = $c->dao($c->stash('tenant'));

        unless ($request_id && $action && ($action eq 'approve' || $action eq 'deny')) {
            return $c->render(json => { error => 'Request ID and valid action required' }, status => 400);
        }

        try {
            # Find the drop request
            my $drop_request = Registry::DAO::DropRequest->find($dao->db, { id => $request_id });
            return $c->render(json => { error => 'Drop request not found' }, status => 404) unless $drop_request;

            if ($drop_request->status ne 'pending') {
                return $c->render(json => { error => 'Drop request has already been processed' }, status => 400);
            }

            if ($action eq 'approve') {
                $drop_request->approve($dao->db, $user, $admin_notes, $refund_amount);

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
                $drop_request->deny($dao->db, $user, $admin_notes);

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