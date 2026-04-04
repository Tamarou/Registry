use 5.42.0;
use utf8;

use Object::Pad;

class Registry::Controller::Waitlist :isa(Registry::Controller) {
    use DateTime;

    # Show waitlist offer page
    method show () {
        my $user = $self->stash('current_user');
        return $self->render(status => 401, text => 'Unauthorized') unless $user;

        my $waitlist_id = $self->param('id');
        my $db = $self->dao->db;

        # Get the waitlist entry
        my $waitlist_entry = Registry::DAO::Waitlist->find($db, { id => $waitlist_id });
        return $self->render(status => 404, text => 'Waitlist entry not found') unless $waitlist_entry;

        # Check if user is the parent
        return $self->render(status => 403, text => 'Forbidden')
            unless $waitlist_entry->parent_id eq $user->{id};

        # Check if offer is still active
        unless ($waitlist_entry->offer_is_active($db)) {
            return $self->render(template => 'waitlist/expired',
                                 waitlist_entry => $waitlist_entry);
        }

        # Get related objects
        my $session = $waitlist_entry->session($db);
        my $location = $waitlist_entry->location($db);
        my $student = $waitlist_entry->family_member($db) || $waitlist_entry->student($db);

        # Calculate time remaining
        my $expires_at = DateTime->from_epoch(epoch => $waitlist_entry->expires_at);
        my $now = DateTime->now;
        my $time_remaining = $expires_at->subtract_datetime($now);

        $self->stash(
            waitlist_entry => $waitlist_entry,
            session => $session,
            location => $location,
            student => $student,
            expires_at => $expires_at,
            time_remaining => $time_remaining
        );

        $self->render(template => 'waitlist/offer');
    }

    # Accept waitlist offer
    method accept () {
        my $user = $self->stash('current_user');
        return $self->render(status => 401, text => 'Unauthorized') unless $user;

        my $waitlist_id = $self->param('id');
        my $db = $self->dao->db;

        # Get the waitlist entry
        my $waitlist_entry = Registry::DAO::Waitlist->find($db, { id => $waitlist_id });
        return $self->render(status => 404, text => 'Waitlist entry not found') unless $waitlist_entry;

        # Check if user is the parent
        return $self->render(status => 403, text => 'Forbidden')
            unless $waitlist_entry->parent_id eq $user->{id};

        try {
            # Accept the offer
            $waitlist_entry->accept_offer($db);

            # Get session info for confirmation
            my $session = $waitlist_entry->session($db);
            my $student = $waitlist_entry->family_member($db) || $waitlist_entry->student($db);

            if ($self->accepts('', 'html')) {
                $self->flash(success => "Successfully enrolled " . ($student ? $student->name : 'your child') .
                                       " in " . $session->name);
                return $self->redirect_to('parent_dashboard');
            } else {
                return $self->render(json => {
                    success => 1,
                    message => "Waitlist offer accepted successfully"
                });
            }
        }
        catch ($e) {
            if ($self->accepts('', 'html')) {
                $self->flash(error => "Failed to accept offer: $e");
                return $self->redirect_to('waitlist_show', id => $waitlist_id);
            } else {
                return $self->render(json => { error => "Failed to accept offer: $e" }, status => 400);
            }
        }
    }

    # Decline waitlist offer
    method decline () {
        my $user = $self->stash('current_user');
        return $self->render(status => 401, text => 'Unauthorized') unless $user;

        my $waitlist_id = $self->param('id');
        my $db = $self->dao->db;

        # Get the waitlist entry
        my $waitlist_entry = Registry::DAO::Waitlist->find($db, { id => $waitlist_id });
        return $self->render(status => 404, text => 'Waitlist entry not found') unless $waitlist_entry;

        # Check if user is the parent
        return $self->render(status => 403, text => 'Forbidden')
            unless $waitlist_entry->parent_id eq $user->{id};

        try {
            # Decline the offer (this will automatically process next person)
            my $next_entry = $waitlist_entry->decline_offer($db);

            # Get session info for confirmation
            my $session = $waitlist_entry->session($db);
            my $student = $waitlist_entry->family_member($db) || $waitlist_entry->student($db);

            if ($self->accepts('', 'html')) {
                $self->flash(info => "Declined offer for " . ($student ? $student->name : 'your child') .
                                    " in " . $session->name . ". They remain on the waitlist.");
                return $self->redirect_to('parent_dashboard');
            } else {
                return $self->render(json => {
                    success => 1,
                    message => "Waitlist offer declined successfully",
                    next_processed => $next_entry ? 1 : 0
                });
            }
        }
        catch ($e) {
            if ($self->accepts('', 'html')) {
                $self->flash(error => "Failed to decline offer: $e");
                return $self->redirect_to('waitlist_show', id => $waitlist_id);
            } else {
                return $self->render(json => { error => "Failed to decline offer: $e" }, status => 400);
            }
        }
    }

    # Show parent's waitlist status
    method parent_status () {
        my $user = $self->stash('current_user');
        return $self->render(status => 401, text => 'Unauthorized') unless $user;

        my $db = $self->dao->db;

        # Get all waitlist entries for this parent
        my $waitlist_entries = $db->select('waitlist', '*', {
            parent_id => $user->{id},
            status => ['waiting', 'offered']
        })->hashes->to_array;

        # Convert to objects and get related data
        my @entries_with_data;
        for my $entry_data (@$waitlist_entries) {
            my $entry = Registry::DAO::Waitlist->new(%$entry_data);
            my $session = $entry->session($db);
            my $location = $entry->location($db);
            my $student = $entry->family_member($db) || $entry->student($db);

            push @entries_with_data, {
                entry => $entry,
                session => $session,
                location => $location,
                student => $student
            };
        }

        $self->stash(waitlist_entries => \@entries_with_data);
        $self->render(template => 'waitlist/parent_status');
    }
}
