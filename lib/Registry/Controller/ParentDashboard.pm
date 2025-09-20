use 5.40.2;
use utf8;
use experimental qw(signatures try);
use Object::Pad;

class Registry::Controller::ParentDashboard :isa(Registry::Controller) {
    
    # Main parent dashboard
    method index ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden') 
            unless $user->{role} eq 'parent' || $user->{user_type} eq 'parent';
        
        my $dao = $c->dao($c->stash('tenant'));

        # Get all dashboard data
        my $dashboard_data = $self->_get_dashboard_data($dao->db, $user->{id});
        
        # Pass data to template
        $c->stash(%$dashboard_data);
        $c->render(template => 'parent_dashboard/index');
    }
    
    # Get upcoming events calendar (HTMX endpoint)
    method upcoming_events ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;

        my $dao = $c->dao($c->stash('tenant'));
        my $days = $c->param('days') || 7; # Default to next 7 days

        require Registry::DAO::Event;
        my $upcoming_events = Registry::DAO::Event->get_upcoming_for_parent($dao->db, $user->{id}, $days);

        $c->stash(upcoming_events => $upcoming_events);
        $c->render(template => 'parent_dashboard/upcoming_events', layout => undef);
    }
    
    # Get recent attendance (HTMX endpoint)
    method recent_attendance ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;

        my $dao = $c->dao($c->stash('tenant'));
        my $limit = $c->param('limit') || 10;

        require Registry::DAO::Attendance;
        my $recent_attendance = Registry::DAO::Attendance->get_recent_for_parent($dao->db, $user->{id}, $limit);

        $c->stash(recent_attendance => $recent_attendance);
        $c->render(template => 'parent_dashboard/recent_attendance', layout => undef);
    }
    
    # Get unread messages count (HTMX endpoint)
    method unread_messages_count ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;

        my $dao = $c->dao($c->stash('tenant'));

        require Registry::DAO::Message;
        my $unread_count = Registry::DAO::Message->get_unread_count($dao->db, $user->{id});

        $c->render(json => { unread_count => $unread_count });
    }

    # Private helper methods
    
    # Get all dashboard data
    method _get_dashboard_data ($db, $parent_id) {
        require Registry::DAO::FamilyMember;
        require Registry::DAO::Enrollment;
        require Registry::DAO::Event;
        require Registry::DAO::Attendance;
        require Registry::DAO::Message;
        require Registry::DAO::Waitlist;

        return {
            children => Registry::DAO::FamilyMember->get_children_for_parent($db, $parent_id),
            enrollments => Registry::DAO::Enrollment->get_active_for_parent($db, $parent_id),
            upcoming_events => Registry::DAO::Event->get_upcoming_for_parent($db, $parent_id, 7),
            recent_attendance => Registry::DAO::Attendance->get_recent_for_parent($db, $parent_id, 5),
            recent_messages => Registry::DAO::Message->get_recent_for_parent($db, $parent_id, 5),
            waitlist_entries => Registry::DAO::Waitlist->get_entries_for_parent($db, $parent_id),
            unread_message_count => Registry::DAO::Message->get_unread_count($db, $parent_id),
            dashboard_stats => Registry::DAO::Enrollment->get_dashboard_stats_for_parent($db, $parent_id)
        };
    }
}