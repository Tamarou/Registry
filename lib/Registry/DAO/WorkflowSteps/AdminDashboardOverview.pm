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
    return {
        %{ $self->_load_full_dashboard($db) },
        payments_blocked =>
          $self->_payments_blocked( $db, ( $run->data || {} )->{__tenant_slug} ),
    };
}

# Whether this tenant has published something it cannot be paid for.
#
# The publish gate refuses a priced session while the tenant is not Connect
# ready, and the checkout refuses the charge -- but a Connect account can stop
# working after publication (Stripe restricting an account does exactly that),
# and then the first person to find out is a parent at checkout who has no reason
# to tell anybody. #410 settled that the gate stays, so the tenant has to be told
# here, where they can act on it.
#
# Conditional on actually having a priced published session, deliberately. A
# tenant running free programmes needs no Connect account, and the publish gate
# lets them publish without one -- warning them would be nagging about a setup
# step they do not need.
method _payments_blocked ( $db, $tenant_slug ) {
    return undef unless defined $tenant_slug && length $tenant_slug;

    require Registry::DAO::Tenant;

    # registry-qualified: this runs on the tenant's own schema, where
    # clone_schema has left an empty copy of `tenants`.
    my $row = $db->query(
        'SELECT * FROM registry.tenants WHERE slug = ?', $tenant_slug )->hash;
    my $tenant = $row ? Registry::DAO::Tenant->new(%$row) : undef;
    return undef if $tenant && $tenant->stripe_connect_ready;

    my $priced = $db->query( q{
        SELECT COUNT(DISTINCT s.id)
          FROM sessions s
          JOIN pricing_plans p ON p.session_id = s.id
         WHERE s.status = 'published'
           AND p.superseded_at IS NULL
           AND p.amount_cents > 0
    } )->array->[0] // 0;

    return undef unless $priced;

    return {
        sessions     => 0 + $priced,
        action_url   => '/admin/billing',
        action_label => 'Set up payments',
    };
}

method _load_full_dashboard ($db) {
    require Registry::DAO::AdminDashboard;

    # Load overview stats directly (simple aggregate queries, unlikely to fail)
    my $overview_stats = eval { Registry::DAO::AdminDashboard->get_overview_stats($db) } || {};

    # Load each section independently so one failure doesn't block the page
    my $programs      = eval { $self->_load_section($db, 'program_overview', {})->{programs} } || [];
    my $events        = eval { $self->_load_section($db, 'todays_events', {})->{events} } || [];
    my $waitlist_data = eval { $self->_load_section($db, 'waitlist_management', {})->{waitlist_data} } || [];
    my $notifications = eval { $self->_load_section($db, 'recent_notifications', {})->{notifications} } || [];
    my $enrollment_alerts = eval { Registry::DAO::AdminDashboard->get_enrollment_alerts($db) } || [];
    my $waitlist_summary  = eval { Registry::DAO::AdminDashboard->get_waitlist_summary($db) } || [];

    return {
        overview_stats    => $overview_stats,
        enrollment_alerts => $enrollment_alerts,
        waitlist_summary  => $waitlist_summary,
        programs          => $programs,
        program_summary   => $programs,   # alias for bulk message modal
        time_range        => 'current',
        events            => $events,
        selected_date     => DateTime->now->ymd,
        waitlist_data     => $waitlist_data,
        status_filter     => 'all',
        notifications     => $notifications,
        type_filter       => 'all',
    };
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
