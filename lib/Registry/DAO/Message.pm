use 5.40.2;
use utf8;
use experimental qw(try);
use Object::Pad;

class Registry::DAO::Message :isa(Registry::DAO::Object) {
    use Carp qw( croak );
    use JSON qw( decode_json encode_json );
    use DateTime;
    
    field $id :param :reader;
    field $sender_id :param :reader;
    field $subject :param :reader;
    field $body :param :reader;
    field $message_type :param :reader;
    field $scope :param :reader;
    field $scope_id :param :reader;
    field $scheduled_for :param :reader;
    field $sent_at :param :reader;
    field $created_at :param :reader;
    field $updated_at :param :reader;
    
    sub table { 'messages' }
    
    ADJUST {
        # Validate message type
        unless ($message_type && $message_type =~ /^(announcement|update|emergency)$/) {
            croak "Invalid message type: must be 'announcement', 'update', or 'emergency'";
        }
        
        # Validate scope
        unless ($scope && $scope =~ /^(program|session|child-specific|location|tenant-wide)$/) {
            croak "Invalid scope: must be 'program', 'session', 'child-specific', 'location', or 'tenant-wide'";
        }
    }
    
    sub create ($class, $db, $data) {
        # Validate required fields
        for my $field (qw(sender_id subject body message_type scope)) {
            croak "Missing required field: $field" unless $data->{$field};
        }
        
        $class->SUPER::create($db, $data);
    }
    
    # Send a message to specified recipients
    sub send_message ($class, $db, $message_data, $recipient_ids, %opts) {
        $db = $db->db if $db isa Registry::DAO;
        try {
            my $tx = $db->begin;
            
            # Create the message
            my $message = $class->create($db, {
                %$message_data,
                sent_at => $opts{send_now} ? \'now()' : undef
            });
            
            # Add recipients
            for my $recipient_id (@$recipient_ids) {
                $db->insert('message_recipients', {
                    message_id => $message->id,
                    recipient_id => $recipient_id,
                    recipient_type => $opts{recipient_type} || 'parent'
                });
            }
            
            $tx->commit;
            
            # If sending now and no scheduling, integrate with notification system
            if ($opts{send_now} && !$message_data->{scheduled_for}) {
                $class->_send_notifications($db, $message, $recipient_ids, %opts);
            }
            
            return $message;
        }
        catch ($e) {
            croak "Failed to send message: $e";
        }
    }
    
    # Send notifications via the notification system
    sub _send_notifications ($class, $db, $message, $recipient_ids, %opts) {
        $db = $db->db if $db isa Registry::DAO;
        require Registry::DAO::Notification;
        require Registry::DAO::UserPreference;
        
        for my $recipient_id (@$recipient_ids) {
            # Check if user wants message notifications via email
            if (Registry::DAO::UserPreference->wants_notification(
                $db, $recipient_id, 'message_' . $message->message_type, 'email'
            )) {
                Registry::DAO::Notification->create($db, {
                    user_id => $recipient_id,
                    type => 'message_' . $message->message_type,
                    channel => 'email',
                    subject => $message->subject,
                    message => $message->body,
                    metadata => { 
                        message_id => $message->id,
                        scope => $message->scope,
                        scope_id => $message->scope_id 
                    }
                })->send($db);
            }
            
            # Check if user wants message notifications via in-app
            if (Registry::DAO::UserPreference->wants_notification(
                $db, $recipient_id, 'message_' . $message->message_type, 'in_app'
            )) {
                Registry::DAO::Notification->create($db, {
                    user_id => $recipient_id,
                    type => 'message_' . $message->message_type,
                    channel => 'in_app',
                    subject => $message->subject,
                    message => $message->body,
                    metadata => { 
                        message_id => $message->id,
                        scope => $message->scope,
                        scope_id => $message->scope_id 
                    }
                })->send($db);
            }
            
            # Mark as delivered
            $db->update('message_recipients', 
                { delivered_at => \'now()' },
                { message_id => $message->id, recipient_id => $recipient_id }
            );
        }
    }
    
    # Get messages for a parent (includes child-specific and relevant program/session messages)
    sub get_messages_for_parent ($class, $db, $parent_id, %opts) {
        $db = $db->db if $db isa Registry::DAO;
        my $limit = $opts{limit} || 50;
        my $offset = $opts{offset} || 0;
        
        # Get messages where parent is a direct recipient
        my $sql = q{
            SELECT DISTINCT 
                m.id, m.sender_id, m.subject, m.body, m.message_type, 
                m.scope, m.scope_id, m.scheduled_for, m.sent_at, 
                m.created_at, m.updated_at,
                mr.delivered_at, mr.read_at,
                up.name as sender_name,
                CASE 
                    WHEN m.scope = 'program' THEN p.name
                    WHEN m.scope = 'session' THEN s.name
                    WHEN m.scope = 'location' THEN l.name
                    ELSE 'General'
                END as scope_name
            FROM messages m
            JOIN message_recipients mr ON m.id = mr.message_id
            LEFT JOIN user_profiles up ON m.sender_id = up.user_id
            LEFT JOIN projects p ON m.scope = 'program' AND m.scope_id = p.id
            LEFT JOIN sessions s ON m.scope = 'session' AND m.scope_id = s.id  
            LEFT JOIN locations l ON m.scope = 'location' AND m.scope_id = l.id
            WHERE mr.recipient_id = ? 
              AND mr.recipient_type = 'parent'
              AND m.sent_at IS NOT NULL
        };
        
        # Add filters
        if ($opts{message_type}) {
            $sql .= ' AND m.message_type = ?';
        }
        if ($opts{unread_only}) {
            $sql .= ' AND mr.read_at IS NULL';
        }
        
        $sql .= ' ORDER BY m.created_at DESC LIMIT ? OFFSET ?';
        
        my @params = ($parent_id);
        push @params, $opts{message_type} if $opts{message_type};
        push @params, $limit, $offset;
        
        return $db->query($sql, @params)->hashes->to_array;
    }
    
    # Get recipients for a specific scope (program, session, etc.)
    sub get_recipients_for_scope ($class, $db, $scope, $scope_id = undef, %opts) {
        $db = $db->db if $db isa Registry::DAO;
        my $sql;
        my @params;
        
        if ($scope eq 'tenant-wide') {
            # All parents in the tenant
            $sql = q{
                SELECT DISTINCT u.id, up.name, up.email
                FROM users u
                JOIN user_profiles up ON u.id = up.user_id
                WHERE u.user_type = 'parent'
            };
        }
        elsif ($scope eq 'program' && $scope_id) {
            # Parents with children enrolled in the program
            $sql = q{
                SELECT DISTINCT u.id, up.name, up.email
                FROM users u
                JOIN user_profiles up ON u.id = up.user_id
                JOIN family_members fm ON u.id = fm.family_id
                JOIN enrollments e ON fm.id = e.family_member_id
                JOIN sessions s ON e.session_id = s.id
                WHERE s.project_id = ? AND e.status = 'active'
            };
            @params = ($scope_id);
        }
        elsif ($scope eq 'session' && $scope_id) {
            # Parents with children enrolled in the specific session
            $sql = q{
                SELECT DISTINCT u.id, up.name, up.email
                FROM users u
                JOIN user_profiles up ON u.id = up.user_id
                JOIN family_members fm ON u.id = fm.family_id
                JOIN enrollments e ON fm.id = e.family_member_id
                WHERE e.session_id = ? AND e.status = 'active'
            };
            @params = ($scope_id);
        }
        elsif ($scope eq 'location' && $scope_id) {
            # Parents with children enrolled in programs at the location
            $sql = q{
                SELECT DISTINCT u.id, up.name, up.email
                FROM users u
                JOIN user_profiles up ON u.id = up.user_id
                JOIN family_members fm ON u.id = fm.family_id
                JOIN enrollments e ON fm.id = e.family_member_id
                JOIN sessions s ON e.session_id = s.id
                JOIN events ev ON ev.session_id = s.id
                WHERE ev.location_id = ? AND e.status = 'active'
            };
            @params = ($scope_id);
        }
        elsif ($scope eq 'child-specific' && $scope_id) {
            # Parent of the specific child
            $sql = q{
                SELECT u.id, up.name, up.email
                FROM users u
                JOIN user_profiles up ON u.id = up.user_id
                JOIN family_members fm ON u.id = fm.family_id
                WHERE fm.id = ?
            };
            @params = ($scope_id);
        }
        else {
            return [];
        }
        
        return $db->query($sql, @params)->hashes->to_array;
    }
    
    # Mark message as read for a specific recipient
    method mark_as_read ($db, $recipient_id) {
        $db = $db->db if $db isa Registry::DAO;
        $db->update('message_recipients',
            { read_at => \'now()' },
            { message_id => $id, recipient_id => $recipient_id, read_at => undef }
        );
    }
    
    # Get recent messages for parent (moved from ParentDashboard controller)
    sub get_recent_for_parent($class, $db, $parent_id, $limit = 5) {
        return $class->get_messages_for_parent($db, $parent_id, limit => $limit);
    }

    # Get unread message count for a parent
    sub get_unread_count ($class, $db, $parent_id) {
        $db = $db->db if $db isa Registry::DAO;
        my $sql = q{
            SELECT COUNT(*)
            FROM message_recipients mr
            JOIN messages m ON mr.message_id = m.id
            WHERE mr.recipient_id = ? 
              AND mr.recipient_type = 'parent'
              AND mr.read_at IS NULL
              AND m.sent_at IS NOT NULL
        };
        
        return $db->query($sql, $parent_id)->array->[0] || 0;
    }
    
    # Schedule a message for later sending
    method schedule_for_later ($db, $send_time) {
        $self->update($db, { scheduled_for => $send_time });
    }
    
    # Send a scheduled message (called by background job)
    method send_scheduled_message ($db) {
        return if $sent_at; # Already sent
        
        try {
            # Get recipients
            my $recipients = $db->select('message_recipients', 
                ['recipient_id'], 
                { message_id => $id }
            )->arrays->to_array;
            
            my @recipient_ids = map { $_->[0] } @$recipients;
            
            # Send notifications
            $self->_send_notifications($db, $self, \@recipient_ids);
            
            # Mark as sent
            $self->update($db, { sent_at => \'now()' });
            
            return 1;
        }
        catch ($e) {
            warn "Failed to send scheduled message $id: $e";
            return 0;
        }
    }
    
    # Get scheduled messages that are ready to send
    sub get_messages_to_send ($class, $db) {
        $db = $db->db if $db isa Registry::DAO;
        my $sql = q{
            SELECT id, sender_id, subject, body, message_type, scope, scope_id, 
                   scheduled_for, sent_at, created_at, updated_at
            FROM messages
            WHERE scheduled_for <= now() 
              AND sent_at IS NULL
            ORDER BY scheduled_for ASC
        };
        
        my $results = $db->query($sql)->hashes;
        return [ map { $class->new(%$_) } @$results ];
    }
    
    # Get related objects
    method sender ($db) {
        require Registry::DAO::User;
        Registry::DAO::User->find($db, { id => $sender_id });
    }
    
    method recipients ($db) {
        my $results = $db->select('message_recipients',
            ['recipient_id', 'recipient_type', 'delivered_at', 'read_at'],
            { message_id => $id }
        )->hashes;
        
        return $results->to_array;
    }
    
    # Helper methods
    method is_sent { defined $sent_at }
    method is_scheduled { defined $scheduled_for && !defined $sent_at }
    method is_emergency { $message_type eq 'emergency' }
    method is_announcement { $message_type eq 'announcement' }
    method is_update { $message_type eq 'update' }
    
    method scope_description {
        return "All families" if $scope eq 'tenant-wide';
        return "Program: " . ($scope_id || 'Unknown') if $scope eq 'program';
        return "Session: " . ($scope_id || 'Unknown') if $scope eq 'session';
        return "Location: " . ($scope_id || 'Unknown') if $scope eq 'location';
        return "Individual child" if $scope eq 'child-specific';
        return "Unknown scope";
    }
}