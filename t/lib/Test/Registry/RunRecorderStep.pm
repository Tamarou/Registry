# ABOUTME: Test-only workflow step that records which run it was handed.
# ABOUTME: Used to prove WorkflowRun::process passes the run rather than the workflow's latest.
use 5.42.0;
use Object::Pad;

class Test::Registry::RunRecorderStep :isa(Registry::DAO::WorkflowStep) {

    # The fallback every real step carries -- latest_run when no run is passed --
    # is deliberately reproduced here, because the point is to detect when it is
    # taken. A step handed its own run records that id; one left to guess records
    # whichever run started most recently.
    method process ($db, $form_data, $run = undef) {
        $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };
        return { seen_run_id => $run->id };
    }
}

1;
