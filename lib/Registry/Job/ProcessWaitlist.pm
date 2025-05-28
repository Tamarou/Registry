use 5.40.2;
use utf8;
use experimental qw(try);
use Object::Pad;

class Registry::Job::ProcessWaitlist {
    
    # Register the job with Minion
    sub register ($class, $app) {
        $app->minion->add_task(process_waitlist => sub ($job, @args) {
            $class->perform($job, @args);
        });
    }
    
    # Main job performer
    sub perform ($class, $job, $session_id = undef, $enrollment_id = undef) {
        my $app = $job->app;
        my $log = $app->log;
        
        try {
            my $dao = $app->dao;
            
            if ($session_id) {
                # Process specific session waitlist
                $class->process_session_waitlist($dao, $session_id, $log);
            } elsif ($enrollment_id) {
                # Process waitlist due to enrollment cancellation
                $class->process_enrollment_cancellation($dao, $enrollment_id, $log);
            } else {
                # Process all sessions with cancellations in last hour
                $class->process_recent_cancellations($dao, $log);
            }
            
            $job->finish('Waitlist processing completed successfully');
        }
        catch ($e) {
            $log->error("ProcessWaitlist job failed: $e");
            $job->fail("Waitlist processing failed: $e");
        }
    }
    
    # Process waitlist for a specific session
    sub process_session_waitlist ($class, $dao, $session_id, $log) {
        require Registry::DAO::Waitlist;
        require Registry::DAO::Notification;
        
        $log->info("Processing waitlist for session $session_id");
        
        # Check if there's capacity and waitlist entries
        my $capacity = $class->get_session_capacity($dao, $session_id);
        my $enrolled_count = $class->get_enrolled_count($dao, $session_id);
        my $available_spots = $capacity - $enrolled_count;
        
        if ($available_spots <= 0) {
            $log->debug("No available spots for session $session_id");
            return;
        }
        
        # Get waiting entries
        my $waiting_entries = Registry::DAO::Waitlist->get_session_waitlist(
            $dao->db, $session_id, 'waiting'
        );
        
        unless (@$waiting_entries) {
            $log->debug("No waiting entries for session $session_id");
            return;
        }
        
        # Process up to available spots
        my $spots_to_fill = min($available_spots, scalar(@$waiting_entries));
        
        for my $i (0 .. $spots_to_fill - 1) {
            my $entry = $waiting_entries->[$i];
            
            # Offer the spot
            my $offered_entry = Registry::DAO::Waitlist->process_waitlist(
                $dao->db, $session_id, 48  # 48 hours to respond
            );
            
            if ($offered_entry) {
                $log->info("Offered waitlist spot to student " . $offered_entry->student_id . 
                          " for session $session_id");
                
                # Send notification
                $class->send_waitlist_offer_notification($dao, $offered_entry, $log);
            }
        }
    }
    
    # Process waitlist due to enrollment cancellation
    sub process_enrollment_cancellation ($class, $dao, $enrollment_id, $log) {
        require Registry::DAO::Enrollment;
        
        # Get the enrollment to find the session
        my $enrollment = Registry::DAO::Enrollment->find($dao->db, { id => $enrollment_id });
        unless ($enrollment) {
            $log->warn("Enrollment $enrollment_id not found");
            return;
        }
        
        $log->info("Processing waitlist due to enrollment cancellation: $enrollment_id");
        
        # Process the session waitlist
        $class->process_session_waitlist($dao, $enrollment->session_id, $log);
    }
    
    # Process all sessions with recent cancellations
    sub process_recent_cancellations ($class, $dao, $log) {
        # Find sessions with cancellations in the last hour
        my $sql = q{
            SELECT DISTINCT session_id 
            FROM enrollments 
            WHERE status = 'cancelled' 
            AND updated_at > NOW() - INTERVAL '1 hour'
        };
        
        my $sessions = $dao->db->query($sql)->arrays;
        
        for my $session_row (@$sessions) {
            my $session_id = $session_row->[0];
            $class->process_session_waitlist($dao, $session_id, $log);
        }
    }
    
    # Send waitlist offer notification
    sub send_waitlist_offer_notification ($class, $dao, $waitlist_entry, $log) {
        require Registry::DAO::Notification;
        require Registry::DAO::UserPreference;
        
        my $parent = $waitlist_entry->parent($dao->db);
        my $session = $waitlist_entry->session($dao->db);
        my $student = $waitlist_entry->family_member($dao->db) || $waitlist_entry->student($dao->db);
        
        unless ($parent && $session) {
            $log->warn("Missing parent or session for waitlist notification");
            return;
        }
        
        # Format expiration time
        my $expires_formatted = DateTime->from_epoch(
            epoch => $waitlist_entry->expires_at
        )->strftime('%B %d, %Y at %I:%M %p');
        
        my $student_name = $student ? $student->name : 'your child';
        my $subject = "Spot Available: $student_name can join " . $session->name;
        my $message = qq{
Good news! A spot has opened up for $student_name in the program "${session->name}".

You have until $expires_formatted to accept this offer.

To accept or decline this offer, please log into your parent dashboard or reply to this email.

Program Details:
- Session: ${session->name}
- Student: $student_name

This offer will expire automatically if not accepted by the deadline.
        };
        
        # Check notification preferences and send
        if (Registry::DAO::UserPreference->wants_notification(
            $dao->db, $parent->id, 'waitlist_offer', 'email'
        )) {
            Registry::DAO::Notification->create($dao->db, {
                user_id => $parent->id,
                type => 'waitlist_offer',
                channel => 'email',
                subject => $subject,
                message => $message,
                metadata => {
                    waitlist_id => $waitlist_entry->id,
                    session_id => $session->id,
                    student_id => $waitlist_entry->student_id,
                    expires_at => $waitlist_entry->expires_at
                }
            })->send($dao->db);
            
            $log->info("Sent waitlist offer email to parent " . $parent->id);
        }
        
        # Send in-app notification
        if (Registry::DAO::UserPreference->wants_notification(
            $dao->db, $parent->id, 'waitlist_offer', 'in_app'
        )) {
            Registry::DAO::Notification->create($dao->db, {
                user_id => $parent->id,
                type => 'waitlist_offer',
                channel => 'in_app',
                subject => $subject,
                message => $message,
                metadata => {
                    waitlist_id => $waitlist_entry->id,
                    session_id => $session->id,
                    student_id => $waitlist_entry->student_id,
                    expires_at => $waitlist_entry->expires_at
                }
            })->send($dao->db);
            
            $log->info("Sent waitlist offer in-app notification to parent " . $parent->id);
        }
    }
    
    # Helper to get session capacity
    sub get_session_capacity ($class, $dao, $session_id) {
        my $sql = q{
            SELECT e.capacity
            FROM events e
            WHERE e.session_id = ?
            LIMIT 1
        };
        
        my $result = $dao->db->query($sql, $session_id)->array;
        return $result ? $result->[0] : 0;
    }
    
    # Helper to get enrolled count
    sub get_enrolled_count ($class, $dao, $session_id) {
        my $sql = q{
            SELECT COUNT(*)
            FROM enrollments
            WHERE session_id = ? AND status IN ('active', 'pending')
        };
        
        return $dao->db->query($sql, $session_id)->array->[0] || 0;
    }
    
    # Utility function
    sub min ($a, $b) {
        return $a < $b ? $a : $b;
    }
}