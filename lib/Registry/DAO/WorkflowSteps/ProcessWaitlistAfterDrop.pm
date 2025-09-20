# ABOUTME: Processes waitlist for session when enrollment spot opens up from drop
# ABOUTME: Triggers waitlist processing to move next waiting family into the session
use 5.40.2;
use utf8;
use Object::Pad;

class Registry::DAO::WorkflowSteps::ProcessWaitlistAfterDrop :isa(Registry::DAO::WorkflowStep) {

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my ($run)      = $workflow->latest_run($db);
        my $data       = $run->data;

        my $session_id = $data->{session_id}
            or return { waitlist_processed => 0, message => 'No session_id provided' };

        # Process waitlist for the session
        require Registry::DAO::Waitlist;
        my $processed = Registry::DAO::Waitlist->process_waitlist($db, $session_id);

        return {
            waitlist_processed => 1,
            session_id => $session_id,
            enrollments_promoted => $processed || 0,
            message => "Processed waitlist for session $session_id, promoted $processed enrollments"
        };
    }
}