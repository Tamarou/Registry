# ABOUTME: Controller for the parent message center and staff message composition endpoints
# ABOUTME: Handles inbox display, message sending, marking as read, and recipient previews
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::Controller::Messages :isa(Registry::Controller) {
    use Mojo::JSON qw(decode_json);
    use DateTime;
    use DateTime::Format::Pg;

    # Show message center (inbox for parents, compose for staff)
    method index {
        my $user = $self->stash('current_user');
        return $self->render(status => 401, text => 'Unauthorized') unless $user;

        if ($user->{role} eq 'parent' || $user->{user_type} eq 'parent') {
            return $self->_parent_inbox($user);
        } elsif ($user->{role} =~ /^(admin|staff|instructor)$/) {
            return $self->_staff_compose($user);
        } else {
            return $self->render(status => 403, text => 'Forbidden');
        }
    }

    # Parent inbox view
    method _parent_inbox ($user) {
        my $db = $self->dao($self->stash('tenant'))->db;
        my $page = $self->param('page') || 1;
        my $per_page = 20;
        my $offset = ($page - 1) * $per_page;

        # Get messages for parent
        my $messages = Registry::DAO::Message->get_messages_for_parent(
            $db, $user->{id},
            limit => $per_page,
            offset => $offset,
            message_type => $self->param('type'),
            unread_only => $self->param('unread')
        );

        # Get unread count
        my $unread_count = Registry::DAO::Message->get_unread_count($db, $user->{id});

        $self->stash(
            messages => $messages,
            unread_count => $unread_count,
            current_page => $page,
            total_pages => int((@$messages + $per_page - 1) / $per_page)
        );

        $self->render(template => 'messages/parent_inbox');
    }

    # Staff message composition view
    method _staff_compose ($user) {
        my $db = $self->dao($self->stash('tenant'))->db;

        # Get available programs, sessions, locations for scope selection
        my $programs = $db->select('projects',
            ['id', 'name'],
            { status => 'active' }
        )->hashes->to_array;

        my $sessions = $db->select('sessions',
            ['id', 'name'],
            { status => 'active' }
        )->hashes->to_array;

        my $locations = $db->select('locations',
            ['id', 'name']
        )->hashes->to_array;

        $self->stash(
            programs => $programs,
            sessions => $sessions,
            locations => $locations
        );

        $self->render(template => 'messages/compose');
    }

    # Send a new message
    method create {
        my $user = $self->stash('current_user');
        return $self->render(status => 401, text => 'Unauthorized') unless $user;
        return $self->render(status => 403, text => 'Forbidden')
            unless $user->{role} =~ /^(admin|staff|instructor)$/;

        my $db = $self->dao($self->stash('tenant'))->db;

        # Validate required fields
        my $subject = $self->param('subject');
        my $body = $self->param('body');
        my $message_type = $self->param('message_type');
        my $scope = $self->param('scope');
        my $scope_id = $self->param('scope_id');
        my $send_now = $self->param('send_now');
        my $scheduled_for = $self->param('scheduled_for');

        unless ($subject && $body && $message_type && $scope) {
            return $self->render(json => {
                error => 'Subject, body, message type, and scope are required'
            }, status => 400);
        }

        try {
            # Get recipients based on scope
            my $recipients = Registry::DAO::Message->get_recipients_for_scope(
                $db, $scope, $scope_id
            );

            unless (@$recipients) {
                return $self->render(json => {
                    error => 'No recipients found for the selected scope'
                }, status => 400);
            }

            my @recipient_ids = map { $_->{id} } @$recipients;

            # Prepare message data
            my $message_data = {
                sender_id => $user->{id},
                subject => $subject,
                body => $body,
                message_type => $message_type,
                scope => $scope,
                scope_id => $scope_id || undef,
                scheduled_for => $scheduled_for ?
                    DateTime::Format::Pg->parse_datetime($scheduled_for) : undef
            };

            # Send the message
            my $message = Registry::DAO::Message->send_message(
                $db, $message_data, \@recipient_ids,
                send_now => $send_now,
                recipient_type => 'parent'
            );

            # Return success response
            my $response = {
                success => 1,
                message_id => $message->id,
                recipients_count => scalar(@recipient_ids),
                sent_now => $send_now ? 1 : 0
            };

            if ($self->accepts('', 'html')) {
                $self->flash(success => "Message sent to " . scalar(@recipient_ids) . " recipients");
                return $self->redirect_to('messages_index');
            } else {
                return $self->render(json => $response);
            }
        }
        catch ($e) {
            if ($self->accepts('', 'html')) {
                $self->flash(error => "Failed to send message: $e");
                return $self->redirect_to('messages_index');
            } else {
                return $self->render(json => { error => "Failed to send message: $e" }, status => 500);
            }
        }
    }

    # Show a specific message
    method show {
        my $user = $self->stash('current_user');
        return $self->render(status => 401, text => 'Unauthorized') unless $user;

        my $message_id = $self->param('id');
        my $db = $self->dao($self->stash('tenant'))->db;

        # Get the message
        my $message = Registry::DAO::Message->find($db, { id => $message_id });
        return $self->render(status => 404, text => 'Message not found') unless $message;

        # Check if user has access to this message
        if ($user->{role} eq 'parent' || $user->{user_type} eq 'parent') {
            # Verify parent is a recipient
            my $recipient = $db->select('message_recipients',
                ['*'],
                { message_id => $message_id, recipient_id => $user->{id} }
            )->hash;

            return $self->render(status => 403, text => 'Forbidden') unless $recipient;

            # Mark as read
            $message->mark_as_read($db, $user->{id});
        } elsif ($user->{role} !~ /^(admin|staff|instructor)$/) {
            return $self->render(status => 403, text => 'Forbidden');
        }

        # Get sender info
        my $sender = $message->sender($db);
        my $recipients = $message->recipients($db);

        $self->stash(
            message => $message,
            sender => $sender,
            recipients => $recipients
        );

        $self->render(template => 'messages/show');
    }

    # Mark message as read (AJAX endpoint)
    method mark_read {
        my $user = $self->stash('current_user');
        return $self->render(status => 401, text => 'Unauthorized') unless $user;
        return $self->render(status => 403, text => 'Forbidden')
            unless $user->{role} eq 'parent' || $user->{user_type} eq 'parent';

        my $message_id = $self->param('id');
        my $db = $self->dao($self->stash('tenant'))->db;

        my $message = Registry::DAO::Message->find($db, { id => $message_id });
        return $self->render(status => 404, text => 'Message not found') unless $message;

        # Verify parent is a recipient
        my $recipient = $db->select('message_recipients',
            ['*'],
            { message_id => $message_id, recipient_id => $user->{id} }
        )->hash;

        return $self->render(status => 403, text => 'Forbidden') unless $recipient;

        # Mark as read
        $message->mark_as_read($db, $user->{id});

        $self->render(json => { success => 1 });
    }

    # Get recipients preview for a scope (AJAX endpoint)
    method preview_recipients {
        my $user = $self->stash('current_user');
        return $self->render(status => 401, text => 'Unauthorized') unless $user;
        return $self->render(status => 403, text => 'Forbidden')
            unless $user->{role} =~ /^(admin|staff|instructor)$/;

        my $scope = $self->param('scope');
        my $scope_id = $self->param('scope_id');
        my $db = $self->dao($self->stash('tenant'))->db;

        my $recipients = Registry::DAO::Message->get_recipients_for_scope(
            $db, $scope, $scope_id
        );

        $self->render(json => {
            count => scalar(@$recipients),
            recipients => $recipients
        });
    }

    # Get unread message count (AJAX endpoint)
    method unread_count {
        my $user = $self->stash('current_user');
        return $self->render(status => 401, text => 'Unauthorized') unless $user;
        return $self->render(status => 403, text => 'Forbidden')
            unless $user->{role} eq 'parent' || $user->{user_type} eq 'parent';

        my $db = $self->dao($self->stash('tenant'))->db;
        my $count = Registry::DAO::Message->get_unread_count($db, $user->{id});

        $self->render(json => { unread_count => $count });
    }
}
