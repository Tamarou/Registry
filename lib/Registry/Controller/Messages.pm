use 5.40.2;
use utf8;
use experimental qw(signatures);
use Object::Pad;

class Registry::Controller::Messages :isa(Registry::Controller) {
    use Mojo::JSON qw(decode_json);
    use DateTime;
    use DateTime::Format::Pg;
    
    # Show message center (inbox for parents, compose for staff)
    method index ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        
        if ($user->{role} eq 'parent' || $user->{user_type} eq 'parent') {
            return $self->_parent_inbox($c, $user);
        } elsif ($user->{role} =~ /^(admin|staff|instructor)$/) {
            return $self->_staff_compose($c, $user);
        } else {
            return $c->render(status => 403, text => 'Forbidden');
        }
    }
    
    # Parent inbox view
    method _parent_inbox ($c, $user) {
        my $db = $c->app->db($c->stash('tenant'));
        my $page = $c->param('page') || 1;
        my $per_page = 20;
        my $offset = ($page - 1) * $per_page;
        
        # Get messages for parent
        my $messages = Registry::DAO::Message->get_messages_for_parent(
            $db, $user->{id},
            limit => $per_page,
            offset => $offset,
            message_type => $c->param('type'),
            unread_only => $c->param('unread')
        );
        
        # Get unread count
        my $unread_count = Registry::DAO::Message->get_unread_count($db, $user->{id});
        
        $c->stash(
            messages => $messages,
            unread_count => $unread_count,
            current_page => $page,
            total_pages => int((@$messages + $per_page - 1) / $per_page)
        );
        
        $c->render(template => 'messages/parent_inbox');
    }
    
    # Staff message composition view
    method _staff_compose ($c, $user) {
        my $db = $c->app->db($c->stash('tenant'));
        
        # Get available programs, sessions, locations for scope selection
        my $programs = $db->select('projects', 
            ['id', 'name'], 
            { status => 'active' }
        )->hashes->to_array;
        
        my $sessions = $db->select('sessions', 
            ['id', 'name', 'project_id'], 
            { status => 'active' }
        )->hashes->to_array;
        
        my $locations = $db->select('locations', 
            ['id', 'name']
        )->hashes->to_array;
        
        $c->stash(
            programs => $programs,
            sessions => $sessions,
            locations => $locations
        );
        
        $c->render(template => 'messages/compose');
    }
    
    # Send a new message
    method create ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden') 
            unless $user->{role} =~ /^(admin|staff|instructor)$/;
        
        my $db = $c->app->db($c->stash('tenant'));
        
        # Validate required fields
        my $subject = $c->param('subject');
        my $body = $c->param('body');
        my $message_type = $c->param('message_type');
        my $scope = $c->param('scope');
        my $scope_id = $c->param('scope_id');
        my $send_now = $c->param('send_now');
        my $scheduled_for = $c->param('scheduled_for');
        
        unless ($subject && $body && $message_type && $scope) {
            return $c->render(json => { 
                error => 'Subject, body, message type, and scope are required' 
            }, status => 400);
        }
        
        try {
            # Get recipients based on scope
            my $recipients = Registry::DAO::Message->get_recipients_for_scope(
                $db, $scope, $scope_id
            );
            
            unless (@$recipients) {
                return $c->render(json => { 
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
            
            if ($c->accepts('', 'html')) {
                $c->flash(success => "Message sent to " . scalar(@recipient_ids) . " recipients");
                return $c->redirect_to('messages_index');
            } else {
                return $c->render(json => $response);
            }
        }
        catch ($e) {
            if ($c->accepts('', 'html')) {
                $c->flash(error => "Failed to send message: $e");
                return $c->redirect_to('messages_index');
            } else {
                return $c->render(json => { error => "Failed to send message: $e" }, status => 500);
            }
        }
    }
    
    # Show a specific message
    method show ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        
        my $message_id = $c->param('id');
        my $db = $c->app->db($c->stash('tenant'));
        
        # Get the message
        my $message = Registry::DAO::Message->find($db, { id => $message_id });
        return $c->render(status => 404, text => 'Message not found') unless $message;
        
        # Check if user has access to this message
        if ($user->{role} eq 'parent' || $user->{user_type} eq 'parent') {
            # Verify parent is a recipient
            my $recipient = $db->select('message_recipients',
                ['*'],
                { message_id => $message_id, recipient_id => $user->{id} }
            )->hash;
            
            return $c->render(status => 403, text => 'Forbidden') unless $recipient;
            
            # Mark as read
            $message->mark_as_read($db, $user->{id});
        } elsif ($user->{role} !~ /^(admin|staff|instructor)$/) {
            return $c->render(status => 403, text => 'Forbidden');
        }
        
        # Get sender info
        my $sender = $message->sender($db);
        my $recipients = $message->recipients($db);
        
        $c->stash(
            message => $message,
            sender => $sender,
            recipients => $recipients
        );
        
        $c->render(template => 'messages/show');
    }
    
    # Mark message as read (AJAX endpoint)
    method mark_read ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden') 
            unless $user->{role} eq 'parent' || $user->{user_type} eq 'parent';
        
        my $message_id = $c->param('id');
        my $db = $c->app->db($c->stash('tenant'));
        
        my $message = Registry::DAO::Message->find($db, { id => $message_id });
        return $c->render(status => 404, text => 'Message not found') unless $message;
        
        # Verify parent is a recipient
        my $recipient = $db->select('message_recipients',
            ['*'],
            { message_id => $message_id, recipient_id => $user->{id} }
        )->hash;
        
        return $c->render(status => 403, text => 'Forbidden') unless $recipient;
        
        # Mark as read
        $message->mark_as_read($db, $user->{id});
        
        $c->render(json => { success => 1 });
    }
    
    # Get recipients preview for a scope (AJAX endpoint)
    method preview_recipients ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden') 
            unless $user->{role} =~ /^(admin|staff|instructor)$/;
        
        my $scope = $c->param('scope');
        my $scope_id = $c->param('scope_id');
        my $db = $c->app->db($c->stash('tenant'));
        
        my $recipients = Registry::DAO::Message->get_recipients_for_scope(
            $db, $scope, $scope_id
        );
        
        $c->render(json => {
            count => scalar(@$recipients),
            recipients => $recipients
        });
    }
    
    # Get unread message count (AJAX endpoint)
    method unread_count ($c) {
        my $user = $c->stash('current_user');
        return $c->render(status => 401, text => 'Unauthorized') unless $user;
        return $c->render(status => 403, text => 'Forbidden') 
            unless $user->{role} eq 'parent' || $user->{user_type} eq 'parent';
        
        my $db = $c->app->db($c->stash('tenant'));
        my $count = Registry::DAO::Message->get_unread_count($db, $user->{id});
        
        $c->render(json => { unread_count => $count });
    }
}