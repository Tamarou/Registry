use 5.40.2;
use utf8;
use experimental qw(try);
use Object::Pad;

class Registry::Job::WaitlistExpiration {
    
    # Register the job with Minion
    sub register ($class, $app) {
        $app->minion->add_task(waitlist_expiration => sub ($job, @args) {
            $class->perform($job, @args);
        });
    }
    
    # Main job performer
    sub perform ($class, $job, $specific_waitlist_id = undef) {
        my $app = $job->app;
        my $log = $app->log;
        
        try {
            my $dao = $app->dao;
            
            if ($specific_waitlist_id) {
                # Expire specific waitlist entry
                $class->expire_specific_entry($dao, $specific_waitlist_id, $log);
            } else {
                # Expire all old offers and process next in line
                $class->expire_all_old_offers($dao, $log);
            }
            
            $job->finish('Waitlist expiration processing completed successfully');
        }
        catch ($e) {
            $log->error("WaitlistExpiration job failed: $e");
            $job->fail("Waitlist expiration failed: $e");
        }
    }
    
    # Expire all old offers and process next entries
    sub expire_all_old_offers ($class, $dao, $log) {
        require Registry::DAO::Waitlist;
        
        $log->info("Checking for expired waitlist offers");
        
        # Get all expired offers
        my $expired_entries = Registry::DAO::Waitlist->expire_old_offers($dao->db);
        
        unless (@$expired_entries) {
            $log->debug("No expired waitlist offers found");
            return;
        }
        
        $log->info("Found " . scalar(@$expired_entries) . " expired waitlist offers");
        
        # Group by session to process efficiently
        my %sessions;
        for my $entry (@$expired_entries) {
            push @{$sessions{$entry->session_id}}, $entry;
        }
        
        # Process each session's waitlist
        for my $session_id (keys %sessions) {
            my $entries = $sessions{$session_id};
            
            $log->info("Processing " . scalar(@$entries) . " expired entries for session $session_id");
            
            # Send expiration notifications
            for my $entry (@$entries) {
                $class->send_expiration_notification($dao, $entry, $log);
            }
            
            # Process next in waitlist
            require Registry::Job::ProcessWaitlist;
            Registry::Job::ProcessWaitlist->process_session_waitlist($dao, $session_id, $log);
        }
    }
    
    # Expire a specific waitlist entry
    sub expire_specific_entry ($class, $dao, $waitlist_id, $log) {
        require Registry::DAO::Waitlist;
        
        my $entry = Registry::DAO::Waitlist->find($dao->db, { id => $waitlist_id });
        unless ($entry) {
            $log->warn("Waitlist entry $waitlist_id not found");
            return;
        }
        
        if ($entry->status ne 'offered') {
            $log->debug("Waitlist entry $waitlist_id is not in offered status");
            return;
        }
        
        if ($entry->expires_at && time() > $entry->expires_at) {
            $log->info("Expiring waitlist entry $waitlist_id");
            
            # Update status to expired
            $entry->update($dao->db, { status => 'expired' });
            
            # Send expiration notification
            $class->send_expiration_notification($dao, $entry, $log);
            
            # Process next in waitlist
            require Registry::Job::ProcessWaitlist;
            Registry::Job::ProcessWaitlist->process_session_waitlist($dao, $entry->session_id, $log);
        }
    }
    
    # Send expiration notification
    sub send_expiration_notification ($class, $dao, $waitlist_entry, $log) {
        require Registry::DAO::Notification;
        require Registry::DAO::UserPreference;
        
        my $parent = $waitlist_entry->parent($dao->db);
        my $session = $waitlist_entry->session($dao->db);
        my $student = $waitlist_entry->family_member($dao->db) || $waitlist_entry->student($dao->db);
        
        unless ($parent && $session) {
            $log->warn("Missing parent or session for expiration notification");
            return;
        }
        
        my $student_name = $student ? $student->name : 'your child';
        my $subject = "Waitlist Offer Expired: " . $session->name;
        my $message = qq{
Your waitlist offer for $student_name in the program "${session->name}" has expired.

We're sorry you weren't able to accept the offer in time. $student_name will remain on the waitlist and will be notified if another spot becomes available.

Current waitlist position: We'll update you on your position when spaces become available.

If you have any questions, please contact us.

Program Details:
- Session: ${session->name}
- Student: $student_name
        };
        
        # Check notification preferences and send
        if (Registry::DAO::UserPreference->wants_notification(
            $dao->db, $parent->id, 'waitlist_expiration', 'email'
        )) {
            Registry::DAO::Notification->create($dao->db, {
                user_id => $parent->id,
                type => 'waitlist_expiration',
                channel => 'email',
                subject => $subject,
                message => $message,
                metadata => {
                    waitlist_id => $waitlist_entry->id,
                    session_id => $session->id,
                    student_id => $waitlist_entry->student_id
                }
            })->send($dao->db);
            
            $log->info("Sent waitlist expiration email to parent " . $parent->id);
        }
        
        # Send in-app notification
        if (Registry::DAO::UserPreference->wants_notification(
            $dao->db, $parent->id, 'waitlist_expiration', 'in_app'
        )) {
            Registry::DAO::Notification->create($dao->db, {
                user_id => $parent->id,
                type => 'waitlist_expiration',
                channel => 'in_app',
                subject => $subject,
                message => $message,
                metadata => {
                    waitlist_id => $waitlist_entry->id,
                    session_id => $session->id,
                    student_id => $waitlist_entry->student_id
                }
            })->send($dao->db);
            
            $log->info("Sent waitlist expiration in-app notification to parent " . $parent->id);
        }
    }
    
    # Schedule expiration job for a specific waitlist entry
    sub schedule_expiration ($class, $app, $waitlist_entry) {
        return unless $waitlist_entry->expires_at;
        
        my $delay = $waitlist_entry->expires_at - time();
        return if $delay <= 0; # Already expired
        
        $app->minion->enqueue('waitlist_expiration', [$waitlist_entry->id], {
            delay => $delay,
            attempts => 3,
            priority => 7
        });
        
        $app->log->info("Scheduled expiration job for waitlist entry " . $waitlist_entry->id . 
                       " in $delay seconds");
    }
}