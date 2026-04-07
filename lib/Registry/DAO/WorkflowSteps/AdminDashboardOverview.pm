# ABOUTME: Single-step admin dashboard workflow step with section-aware data loading.
# ABOUTME: Loads full dashboard or individual sections based on params; stays on page.
use 5.42.0;
use Object::Pad;

require Registry::DAO::WorkflowStep;

class Registry::DAO::WorkflowSteps::AdminDashboardOverview :isa(Registry::DAO::WorkflowStep) {

method process ($db, $data, $run = undef) {
    # Dashboard is read-only; all POSTs stay on the same page.
    # Actual mutations (drop approval, transfer approval) happen
    # via callcc into separate workflows.
    return { stay => 1 };
}

method prepare_template_data ($db, $run, $params = {}) {
    my $section = $params->{section};

    # If a specific section is requested, load only that section's data
    if ($section) {
        return $self->_load_section($db, $section, $params);
    }

    # Full page load: get everything
    return $self->_load_full_dashboard($db);
}

method _load_full_dashboard ($db) {
    require Registry::DAO::AdminDashboard;
    my $data = eval { Registry::DAO::AdminDashboard->get_admin_dashboard_data($db) } || {};

    # Add section-specific data that the initial render includes inline.
    # Each section loads independently so one failure doesn't block the page.
    $data->{programs}      = eval { $self->_load_section($db, 'program_overview', {})->{programs} } || [];
    $data->{time_range}    = 'current';
    $data->{events}        = eval { $self->_load_section($db, 'todays_events', {})->{events} } || [];
    $data->{selected_date} = DateTime->now->ymd;
    $data->{waitlist_data} = eval { $self->_load_section($db, 'waitlist_management', {})->{waitlist_data} } || [];
    $data->{status_filter} = 'all';
    $data->{notifications} = eval { $self->_load_section($db, 'recent_notifications', {})->{notifications} } || [];
    $data->{type_filter}   = 'all';

    return $data;
}

method _load_section ($db, $section, $params) {
    if ($section eq 'program_overview') {
        require Registry::DAO::Project;
        my $range = $params->{range} || 'current';
        return {
            programs   => eval { Registry::DAO::Project->get_program_overview($db, $range) } || [],
            time_range => $range,
            _section   => 'program_overview',
        };
    }
    elsif ($section eq 'todays_events') {
        require Registry::DAO::Event;
        my $date = $params->{date} || DateTime->now->ymd;
        return {
            events        => eval { Registry::DAO::Event->get_events_for_date($db, $date) } || [],
            selected_date => $date,
            _section      => 'todays_events',
        };
    }
    elsif ($section eq 'waitlist_management') {
        require Registry::DAO::Waitlist;
        my $status = $params->{status} || 'all';
        return {
            waitlist_data => eval { Registry::DAO::Waitlist->get_waitlist_management_data($db, $status) } || [],
            status_filter => $status,
            _section      => 'waitlist_management',
        };
    }
    elsif ($section eq 'recent_notifications') {
        require Registry::DAO::Notification;
        my $type   = $params->{type}  || 'all';
        my $limit  = $params->{limit} || 10;
        return {
            notifications => eval { Registry::DAO::Notification->get_recent_for_admin($db, $limit, $type) } || [],
            type_filter   => $type,
            _section      => 'recent_notifications',
        };
    }
    elsif ($section eq 'pending_drop_requests') {
        require Registry::DAO::DropRequest;
        my $status = $params->{status} || 'pending';
        return {
            drop_requests => eval { Registry::DAO::DropRequest->get_detailed_requests($db, $status) } || [],
            status_filter => $status,
            _section      => 'pending_drop_requests',
        };
    }
    elsif ($section eq 'pending_transfer_requests') {
        require Registry::DAO::TransferRequest;
        my $status = $params->{status} || 'pending';
        return {
            transfer_requests => eval { Registry::DAO::TransferRequest->get_detailed_requests($db, $status) } || [],
            status_filter     => $status,
            _section          => 'pending_transfer_requests',
        };
    }

    # Unknown section -- return full dashboard
    return $self->_load_full_dashboard($db);
}

}
