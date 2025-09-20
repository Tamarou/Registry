# ABOUTME: Processes waitlists for both sessions after transfer
# ABOUTME: Handles waitlist for original session (spot opened) and target session if needed
use 5.40.2;
use utf8;
use Object::Pad;

class Registry::DAO::WorkflowSteps::ProcessWaitlistsAfterTransfer :isa(Registry::DAO::WorkflowStep) {

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my ($run)      = $workflow->latest_run($db);
        my $data       = $run->data;

        my $original_session_id = $data->{original_session_id};
        my $target_session_id = $data->{target_session_id};

        my $results = {
            waitlists_processed => 1,
            original_session_promoted => 0,
            target_session_promoted => 0
        };

        # Process waitlist for original session (spot opened up)
        if ($original_session_id) {
            require Registry::DAO::Waitlist;
            my $promoted = Registry::DAO::Waitlist->process_waitlist($db, $original_session_id);
            $results->{original_session_promoted} = $promoted || 0;
        }

        # Note: Target session doesn't typically need waitlist processing
        # since we already validated capacity, but included for completeness
        if ($target_session_id && $target_session_id ne $original_session_id) {
            require Registry::DAO::Waitlist;
            my $promoted = Registry::DAO::Waitlist->process_waitlist($db, $target_session_id);
            $results->{target_session_promoted} = $promoted || 0;
        }

        return $results;
    }
}