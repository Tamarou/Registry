use 5.40.2;
use experimental qw(try);
use Object::Pad;

class Registry::DAO::WorkflowSteps::AttendanceCheck::ScheduleNext :isa(Registry::DAO::WorkflowStep) {

    method process($db, $continuation) {
        my ($workflow) = $self->workflow($db);
        my ($run) = $workflow->latest_run($db);
        
        my $data = $run->data || {};
        
        # Get the app instance from the run context
        my $app = $data->{workflow_context}->{app};
        
        if ($app && $app->can('minion')) {
            try {
                # Use generic workflow executor for scheduling
                use Registry::Job::WorkflowExecutor;
                Registry::Job::WorkflowExecutor->enqueue_workflow(
                    $app,
                    'attendance-check',
                    reschedule => {
                        enabled => 1,
                        delay => 60,
                        attempts => 3,
                        priority => 5
                    },
                    delay => 60
                );
                
                $run->update_data($db, {
                    next_run_scheduled => 1,
                    scheduled_at => time()
                });
            }
            catch ($e) {
                warn "Failed to schedule next attendance check: $e";
                $run->update_data($db, {
                    next_run_scheduled => 0,
                    schedule_error => "$e"
                });
            }
        } else {
            warn "No app context available for scheduling next run";
            $run->update_data($db, {
                next_run_scheduled => 0,
                schedule_error => "No app context available"
            });
        }
        
        return;
    }
}