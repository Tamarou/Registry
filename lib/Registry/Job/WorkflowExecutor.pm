use 5.40.2;
use utf8;
use experimental qw(try);
use Object::Pad;

class Registry::Job::WorkflowExecutor {
    use Carp qw( croak );
    use Registry::DAO::Workflow;
    
    # Register this job with Minion
    sub register ($class, $app) {
        $app->minion->add_task(workflow_executor => sub ($job, @args) {
            $class->new->run($job, @args);
        });
    }
    
    # Main job execution method
    method run ($job, @args) {
        my $opts = $args[0] || {};
        
        # Extract workflow slug and context from job args
        my $workflow_slug = $opts->{workflow_slug} or croak "workflow_slug is required";
        my $context = $opts->{context} || {};
        my $reschedule = $opts->{reschedule} || {};
        
        $job->app->log->info("Starting workflow execution: $workflow_slug");
        
        try {
            # Get database connection
            my $dao = $job->app->dao;
            my $db = $dao->db;
            
            # Get the requested workflow
            my $workflow = Registry::DAO::Workflow->find($db, { slug => $workflow_slug });
            unless ($workflow) {
                croak "Workflow '$workflow_slug' not found";
            }
            
            # Create workflow run with provided context
            my $workflow_run = $workflow->new_run($db, {});
            
            # Store context and app reference in workflow run data
            my $initial_data = {
                workflow_context => { 
                    app => $job->app,
                    job_id => $job->id,
                    %$context 
                }
            };
            
            $workflow_run->process($db, $workflow->first_step($db), $initial_data);
            
            # Process each step in sequence
            my $current_step = $workflow_run->next_step($db);
            while ($current_step) {
                $job->app->log->debug("Processing step: " . $current_step->slug);
                
                # Process the step
                $workflow_run->process($db, $current_step, {});
                
                # Move to next step
                $current_step = $workflow_run->next_step($db);
            }
            
            $job->app->log->info("Workflow '$workflow_slug' completed successfully");
            
            # Handle rescheduling if specified
            if ($reschedule->{enabled}) {
                $self->schedule_next_run($job->app, $workflow_slug, $opts, $reschedule);
            }
        }
        catch ($e) {
            $job->app->log->error("Workflow '$workflow_slug' failed: $e");
            
            # Still try to reschedule if it was requested
            if ($reschedule->{enabled}) {
                $self->schedule_next_run($job->app, $workflow_slug, $opts, $reschedule);
            }
            
            $job->fail($e);
        }
    }
    
    # Schedule the next execution of this workflow
    method schedule_next_run ($app, $workflow_slug, $original_opts, $reschedule) {
        try {
            my $delay = $reschedule->{delay} || 60;  # Default 1 minute
            my $attempts = $reschedule->{attempts} || 3;
            my $priority = $reschedule->{priority} || 5;
            
            $app->minion->enqueue('workflow_executor', [$original_opts], {
                delay => $delay,
                attempts => $attempts,
                priority => $priority
            });
            
            $app->log->debug("Scheduled next run of workflow '$workflow_slug' in ${delay}s");
        }
        catch ($e) {
            $app->log->error("Failed to schedule next run of workflow '$workflow_slug': $e");
        }
    }
    
    # Helper method to start a workflow execution job
    sub enqueue_workflow ($class, $app, $workflow_slug, %opts) {
        my $job_opts = {
            workflow_slug => $workflow_slug,
            context => $opts{context} || {},
            reschedule => $opts{reschedule} || { enabled => 0 }
        };
        
        my $minion_opts = {
            delay => $opts{delay} || 0,
            attempts => $opts{attempts} || 3,
            priority => $opts{priority} || 5
        };
        
        return $app->minion->enqueue('workflow_executor', [$job_opts], $minion_opts);
    }
}