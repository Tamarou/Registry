use 5.40.2;
use utf8;
use experimental qw(try);
use Object::Pad;

class Registry::Job::AttendanceCheck {
    use Registry::Job::WorkflowExecutor;
    
    # Register this job with Minion
    sub register ($class, $app) {
        $app->minion->add_task(attendance_check => sub ($job, @args) {
            $class->new->run($job, @args);
        });
    }
    
    # Main job execution method - now delegates to WorkflowExecutor
    method run ($job, @args) {
        my $opts = $args[0] || {};
        
        # Convert to workflow executor format
        my $workflow_opts = {
            workflow_slug => 'attendance-check',
            context => $opts->{context} || {},
            reschedule => {
                enabled => 1,
                delay => 60,        # 1 minute
                attempts => 3,
                priority => 5
            }
        };
        
        # Delegate to generic workflow executor
        my $executor = Registry::Job::WorkflowExecutor->new;
        $executor->run($job, $workflow_opts);
    }
    
    # Helper method to start attendance check
    sub start_monitoring ($class, $app, %opts) {
        return Registry::Job::WorkflowExecutor->enqueue_workflow(
            $app, 
            'attendance-check',
            reschedule => {
                enabled => 1,
                delay => $opts{interval} || 60,
                attempts => 3,
                priority => 5
            },
            %opts
        );
    }
}