# ABOUTME: Controller for admin-facing dashboard pages and management endpoints
# ABOUTME: Route-level authentication is handled by under() guards in Registry.pm
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::Controller::AdminDashboard :isa(Registry::Controller) {
    use DateTime;
    use List::Util qw(sum max);
    use JSON qw(encode_json);

    # Main admin dashboard
    method index () {
        my $user = $self->stash('current_user');
        my $dao = $self->dao($self->stash('tenant'));

        # Get all dashboard data
        require Registry::DAO::AdminDashboard;
        my $dashboard_data = Registry::DAO::AdminDashboard->get_admin_dashboard_data($dao->db, $user);

        # Pass data to template
        $self->stash(%$dashboard_data);
        $self->render(template => 'admin_dashboard/index');
    }

    # Program overview data (HTMX endpoint)
    method program_overview () {
        my $dao = $self->dao($self->stash('tenant'));
        my $time_range = $self->param('range') || 'current'; # current, upcoming, all

        require Registry::DAO::Project;
        my $programs = Registry::DAO::Project->get_program_overview($dao->db, $time_range);

        $self->stash(programs => $programs, time_range => $time_range);
        $self->render(template => 'admin_dashboard/program_overview', layout => undef);
    }

    # Today's events with attendance (HTMX endpoint)
    method todays_events () {
        my $dao = $self->dao($self->stash('tenant'));
        my $date = $self->param('date') || DateTime->now->ymd; # YYYY-MM-DD format

        require Registry::DAO::Event;
        my $events = Registry::DAO::Event->get_events_for_date($dao->db, $date);

        $self->stash(events => $events, selected_date => $date);
        $self->render(template => 'admin_dashboard/todays_events', layout => undef);
    }

    # Waitlist management data (HTMX endpoint)
    method waitlist_management () {
        my $dao = $self->dao($self->stash('tenant'));
        my $status_filter = $self->param('status') || 'all'; # all, waiting, offered, urgent

        require Registry::DAO::Waitlist;
        my $waitlist_data = Registry::DAO::Waitlist->get_waitlist_management_data($dao->db, $status_filter);

        $self->stash(waitlist_data => $waitlist_data, status_filter => $status_filter);
        $self->render(template => 'admin_dashboard/waitlist_management', layout => undef);
    }

    # Recent notifications (HTMX endpoint)
    method recent_notifications () {
        my $dao = $self->dao($self->stash('tenant'));
        my $limit = $self->param('limit') || 10;
        my $type_filter = $self->param('type') || 'all'; # all, attendance, waitlist, message

        require Registry::DAO::Notification;
        my $notifications = Registry::DAO::Notification->get_recent_for_admin($dao->db, $limit, $type_filter);

        $self->stash(notifications => $notifications, type_filter => $type_filter);
        $self->render(template => 'admin_dashboard/recent_notifications', layout => undef);
    }

    # Enrollment trends data for charts (JSON endpoint)
    method enrollment_trends () {
        my $dao = $self->dao($self->stash('tenant'));
        my $period = $self->param('period') || 'month'; # week, month, quarter

        require Registry::DAO::AdminDashboard;
        my $trends_data = Registry::DAO::AdminDashboard->get_enrollment_trends($dao->db, $period);

        $self->render(json => $trends_data);
    }

    # Export data
    method export_data () {
        my $dao = $self->dao($self->stash('tenant'));
        my $export_type = $self->param('type') || 'enrollments'; # enrollments, attendance, waitlist
        my $format = $self->param('format') || 'csv'; # csv, json

        try {
            require Registry::DAO::AdminDashboard;
            my $data = Registry::DAO::AdminDashboard->get_export_data($dao->db, $export_type);

            # Determine if we should use streaming based on data size
            my $record_count = @$data;
            my $use_streaming = $record_count > 1000; # Stream for datasets > 1000 records

            # Set content disposition header for downloads
            $self->res->headers->content_disposition("attachment; filename=\"${export_type}.${format}\"");

            # For streaming large datasets, set appropriate headers
            if ($use_streaming && $format eq 'csv') {
                $self->res->headers->content_type('text/csv; charset=utf-8');
                $self->res->headers->transfer_encoding('chunked');
            }

            # Use format-based rendering with streaming support
            $self->respond_to(
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
            $self->flash(error => "Export failed: $e");
            return $self->redirect_to('admin_dashboard');
        }
    }

    # Drop request management (HTMX endpoint)
    method pending_drop_requests () {
        my $dao = $self->dao($self->stash('tenant'));
        my $status_filter = $self->param('status') || 'pending'; # pending, approved, denied, all

        my $drop_requests = Registry::DAO::DropRequest->get_detailed_requests($dao->db, $status_filter);

        $self->stash(drop_requests => $drop_requests, status_filter => $status_filter);
        $self->render(template => 'admin_dashboard/pending_drop_requests', layout => undef);
    }

    # Get pending transfer requests (HTMX endpoint)
    method pending_transfer_requests () {
        my $dao = $self->dao($self->stash('tenant'));
        my $status_filter = $self->param('status') || 'pending';

        my $transfer_requests = Registry::DAO::TransferRequest->get_detailed_requests($dao->db, $status_filter);

        $self->stash(transfer_requests => $transfer_requests, status_filter => $status_filter);
        $self->render(template => 'admin_dashboard/pending_transfer_requests', layout => undef);
    }

    # Quick action: Send bulk message
    method send_bulk_message () {
        my $user = $self->stash('current_user');
        my $dao = $self->dao($self->stash('tenant'));
        my $recipient_scope = $self->param('scope'); # program_id, session_id, tenant-wide
        my $subject = $self->param('subject');
        my $message = $self->param('message');
        my $message_type = $self->param('message_type') || 'announcement';

        unless ($subject && $message && $recipient_scope) {
            return $self->render(json => { error => 'Subject, message, and scope are required' }, status => 400);
        }

        try {
            require Registry::DAO::Message;

            # Determine scope and scope_id
            my ($scope, $scope_id) = $self->_parse_recipient_scope($recipient_scope);

            # Get recipients
            my $recipients = Registry::DAO::Message->get_recipients_for_scope($dao->db, $scope, $scope_id);

            unless (@$recipients) {
                return $self->render(json => { error => 'No recipients found for selected scope' }, status => 400);
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

            return $self->render(json => {
                success => 1,
                message_id => $sent_message->id,
                recipients_count => scalar(@recipient_ids)
            });
        }
        catch ($e) {
            return $self->render(json => { error => "Failed to send message: $e" }, status => 500);
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

    # Toggle publish state on a program. Body param `status` must be one
    # of draft/published/closed (same enum as the DB CHECK constraint).
    method set_program_status () {
        my $id     = $self->stash('id');
        my $status = $self->param('status') // '';

        unless (_valid_status($status)) {
            return $self->render(
                json   => { error => "invalid status: $status" },
                status => 400,
            );
        }

        my $dao = $self->dao($self->stash('tenant'));
        require Registry::DAO::Project;
        my $program = Registry::DAO::Project->find($dao->db, { id => $id });
        return $self->render(json => { error => 'not found' }, status => 404)
            unless $program;

        $program->update($dao->db, { status => $status });

        return $self->render(json => {
            id     => $id,
            status => $status,
        });
    }

    # Toggle publish state on a session.
    method set_session_status () {
        my $id     = $self->stash('id');
        my $status = $self->param('status') // '';

        unless (_valid_status($status)) {
            return $self->render(
                json   => { error => "invalid status: $status" },
                status => 400,
            );
        }

        my $dao = $self->dao($self->stash('tenant'));
        require Registry::DAO::Session;
        my $session = Registry::DAO::Session->find($dao->db, { id => $id });
        return $self->render(json => { error => 'not found' }, status => 404)
            unless $session;

        # Publishing a session requires its parent program to be published
        # first (spec rule: program publishes before any sessions).
        if ($status eq 'published') {
            require Registry::DAO::Project;
            my $project_id = $session->project_id($dao->db);
            my $program    = $project_id
                ? Registry::DAO::Project->find($dao->db, { id => $project_id })
                : undef;

            unless ($program && $program->status eq 'published') {
                return $self->render(
                    json   => { error => 'parent program must be published first' },
                    status => 409,
                );
            }
        }

        $session->update($dao->db, { status => $status });

        return $self->render(json => {
            id     => $id,
            status => $status,
        });
    }

    sub _valid_status ($status) {
        return $status eq 'draft'
            || $status eq 'published'
            || $status eq 'closed';
    }
}
