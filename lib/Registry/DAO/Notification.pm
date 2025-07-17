use 5.40.2;
use utf8;
use experimental qw(try);
use Object::Pad;

class Registry::DAO::Notification :isa(Registry::DAO::Object) {
    use Carp qw( croak );
    use Email::Simple;
    use Email::Sender::Simple qw(sendmail);
    
    field $id :param :reader;
    field $user_id :param :reader;
    field $type :param :reader;
    field $channel :param :reader;
    field $subject :param :reader;
    field $message :param :reader;
    field $metadata :param :reader = {};
    field $sent_at :param :reader;
    field $read_at :param :reader;
    field $failed_at :param :reader;
    field $failure_reason :param :reader;
    field $created_at :param :reader;
    field $updated_at :param :reader;
    
    sub table { 'notifications' }
    
    BUILD {
        # Validate type
        unless ($type && $type =~ /^(attendance_missing|attendance_reminder|general)$/) {
            croak "Invalid notification type: must be 'attendance_missing', 'attendance_reminder', or 'general'";
        }
        
        # Validate channel
        unless ($channel && $channel =~ /^(email|in_app|sms)$/) {
            croak "Invalid notification channel: must be 'email', 'in_app', or 'sms'";
        }
    }
    
    sub create ($class, $db, $data) {
        # Validate required fields
        for my $field (qw(user_id type channel subject message)) {
            croak "Missing required field: $field" unless $data->{$field};
        }
        
        # Ensure metadata is a hash ref and encode as JSON
        $data->{metadata} //= {};
        if (exists $data->{metadata} && ref $data->{metadata}) {
            $data->{metadata} = { -json => $data->{metadata} };
        }
        
        $class->SUPER::create($db, $data);
    }
    
    # Send an email notification
    method send_email ($db) {
        return unless $channel eq 'email';
        return if $sent_at; # Already sent
        
        try {
            # Get user email from profile
            my $user_profile = $db->select('user_profiles', ['email', 'name'], { user_id => $user_id })->hash;
            croak "No email found for user $user_id" unless $user_profile && $user_profile->{email};
            
            # Create email
            my $email = Email::Simple->create(
                header => [
                    To      => sprintf('%s <%s>', $user_profile->{name} || 'User', $user_profile->{email}),
                    From    => $ENV{NOTIFICATION_FROM_EMAIL} || 'noreply@registry.example.com',
                    Subject => $subject,
                ],
                body => $message,
            );
            
            # Send email
            sendmail($email);
            
            # Mark as sent
            $self->update($db, { sent_at => \'now()' });
            
            return 1;
        }
        catch ($e) {
            # Mark as failed
            $self->update($db, { 
                failed_at => \'now()',
                failure_reason => $e
            });
            
            # Log the error but don't die
            warn "Failed to send email notification $id: $e";
            return 0;
        }
    }
    
    # Send an in-app notification (just mark as sent for now)
    method send_in_app ($db) {
        return unless $channel eq 'in_app';
        return if $sent_at; # Already sent
        
        # For in-app notifications, we just mark them as sent
        # The UI will query for unread in-app notifications
        $self->update($db, { sent_at => \'now()' });
        return 1;
    }
    
    # Send notification via appropriate channel
    method send ($db) {
        return if $sent_at; # Already sent
        
        if ($channel eq 'email') {
            return $self->send_email($db);
        }
        elsif ($channel eq 'in_app') {
            return $self->send_in_app($db);
        }
        elsif ($channel eq 'sms') {
            # SMS not implemented yet
            $self->update($db, { 
                failed_at => \'now()',
                failure_reason => 'SMS notifications not implemented'
            });
            return 0;
        }
        else {
            croak "Unknown notification channel: $channel";
        }
    }
    
    # Mark notification as read
    method mark_read ($db) {
        return if $read_at; # Already read
        $self->update($db, { read_at => \'now()' });
    }
    
    # Get notifications for a user
    sub get_user_notifications ($class, $db, $user_id, %opts) {
        my $where = { user_id => $user_id };
        
        # Filter by channel if specified
        $where->{channel} = $opts{channel} if $opts{channel};
        
        # Filter by type if specified
        $where->{type} = $opts{type} if $opts{type};
        
        # Filter by read status
        if (defined $opts{unread_only} && $opts{unread_only}) {
            $where->{read_at} = { '=' => undef };
        }
        
        # Limit to recent notifications by default
        my $limit = $opts{limit} || 50;
        
        my $results = $db->select(
            $class->table,
            undef,
            $where,
            { -desc => 'created_at', limit => $limit }
        )->hashes;
        
        return [ map { $class->new(%$_) } @$results ];
    }
    
    # Get unread count for a user
    sub get_unread_count ($class, $db, $user_id, %opts) {
        my $where = { 
            user_id => $user_id, 
            read_at => { '=' => undef },
            sent_at => { '!=' => undef } # Only count sent notifications
        };
        
        # Filter by channel if specified
        $where->{channel} = $opts{channel} if $opts{channel};
        
        my $count = $db->select($class->table, 'count(*)', $where)->array->[0];
        return $count || 0;
    }
    
    # Send attendance missing notification
    sub send_attendance_missing ($class, $db, $user_id, $event_data, %opts) {
        my $channel = $opts{channel} || 'email';
        
        my $subject = sprintf("Attendance Missing - %s", $event_data->{title} || 'Event');
        my $message = sprintf(
            "Hello,\n\nAttendance has not been recorded for the following event:\n\n" .
            "Event: %s\n" .
            "Time: %s\n" .
            "Location: %s\n\n" .
            "Please record attendance as soon as possible.\n\n" .
            "Thank you,\nRegistry System",
            $event_data->{title} || 'Untitled Event',
            $event_data->{start_time} || 'Unknown',
            $event_data->{location_name} || 'Unknown Location'
        );
        
        my $notification = $class->create($db, {
            user_id => $user_id,
            type => 'attendance_missing',
            channel => $channel,
            subject => $subject,
            message => $message,
            metadata => { event_id => $event_data->{id} }
        });
        
        # Send immediately
        $notification->send($db);
        
        return $notification;
    }
    
    # Send attendance reminder notification  
    sub send_attendance_reminder ($class, $db, $user_id, $event_data, %opts) {
        my $channel = $opts{channel} || 'email';
        
        my $subject = sprintf("Attendance Reminder - %s", $event_data->{title} || 'Event');
        my $message = sprintf(
            "Hello,\n\nThis is a reminder to record attendance for the following event:\n\n" .
            "Event: %s\n" .
            "Time: %s\n" .
            "Location: %s\n\n" .
            "Please record attendance when the event begins.\n\n" .
            "Thank you,\nRegistry System",
            $event_data->{title} || 'Untitled Event',
            $event_data->{start_time} || 'Unknown',
            $event_data->{location_name} || 'Unknown Location'
        );
        
        my $notification = $class->create($db, {
            user_id => $user_id,
            type => 'attendance_reminder',
            channel => $channel,
            subject => $subject,
            message => $message,
            metadata => { event_id => $event_data->{id} }
        });
        
        # Send immediately
        $notification->send($db);
        
        return $notification;
    }
    
    # Get related objects
    method user ($db) {
        require Registry::DAO::User;
        Registry::DAO::User->find($db, { id => $user_id });
    }
    
    # Helper methods
    method is_sent { defined $sent_at }
    method is_read { defined $read_at }
    method is_failed { defined $failed_at }
    method is_pending { !$self->is_sent && !$self->is_failed }
    
    method is_attendance_notification {
        $type eq 'attendance_missing' || $type eq 'attendance_reminder';
    }
}