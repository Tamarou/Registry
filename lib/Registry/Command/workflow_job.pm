use 5.40.2;
use Object::Pad;

# ABOUTME: Command-line interface for managing workflow-based background jobs
# ABOUTME: Allows admins to start, stop, and schedule workflows via Minion

class Registry::Command::workflow_job :isa(Mojolicious::Command) {
    use Registry::Job::WorkflowExecutor;
    use Mojo::Util qw(getopt);
    
    sub description { 'Manage workflow-based background jobs' }
    
    sub usage { <<~'USAGE' }
        Usage: APPLICATION workflow_job <command> [OPTIONS]
        
        Commands:
          start <workflow>     Start a workflow job immediately
          schedule <workflow>  Schedule a recurring workflow job
          list                 List all active workflow jobs
          
        Options:
          --interval <seconds>    Set interval for recurring jobs (default: 3600)
          --priority <1-10>       Set job priority (default: 5)
          --context <key=value>   Pass context variables to workflow
          
        Examples:
          # Start attendance check immediately
          ./registry workflow_job start attendance-check
          
          # Schedule daily reports every 24 hours
          ./registry workflow_job schedule daily-reports --interval 86400
          
          # List all active jobs
          ./registry workflow_job list
        USAGE
    
    sub run {
        my ($self, @args) = @_;
        my $command = shift @args or die $self->usage;
        
        getopt(\\@args,
            'i|interval=i'   => \\my $interval,
            'p|priority=i'   => \\my $priority,
            'c|context=s%'   => \\my $context);
            
        $interval //= 3600;  # 1 hour default
        $priority //= 5;
        $context  //= {};
        
        if ($command eq 'start') {
            $self->start_workflow(\\@args, $context, $priority);
        }
        elsif ($command eq 'schedule') {
            $self->schedule_workflow(\\@args, $context, $interval, $priority);
        }
        elsif ($command eq 'list') {
            $self->list_jobs();
        }
        else {
            die "Unknown command: $command\\n" . $self->usage;
        }
    }
    
    sub start_workflow {
        my ($self, $args, $context, $priority) = @_;
        my $workflow_slug = shift @$args or die "Workflow slug required\\n";
        
        # Verify workflow exists
        my $dao = $self->app->dao;
        my $workflow = Registry::DAO::Workflow->find($dao->db, { slug => $workflow_slug });
        unless ($workflow) {
            die "Workflow '$workflow_slug' not found\\n";
        }
        
        say "Starting workflow: $workflow_slug";
        
        my $job_id = Registry::Job::WorkflowExecutor->enqueue_workflow(
            $self->app,
            $workflow_slug,
            context => $context,
            priority => $priority
        );
        
        say "Job enqueued with ID: $job_id";
    }
    
    sub schedule_workflow {
        my ($self, $args, $context, $interval, $priority) = @_;
        my $workflow_slug = shift @$args or die "Workflow slug required\\n";
        
        # Verify workflow exists
        my $dao = $self->app->dao;
        my $workflow = Registry::DAO::Workflow->find($dao->db, { slug => $workflow_slug });
        unless ($workflow) {
            die "Workflow '$workflow_slug' not found\\n";
        }
        
        say "Scheduling recurring workflow: $workflow_slug (every ${interval}s)";
        
        my $job_id = Registry::Job::WorkflowExecutor->enqueue_workflow(
            $self->app,
            $workflow_slug,
            context => $context,
            reschedule => {
                enabled => 1,
                delay => $interval,
                attempts => 3,
                priority => $priority
            },
            priority => $priority
        );
        
        say "Recurring job scheduled with initial ID: $job_id";
    }
    
    sub list_jobs {
        my ($self) = @_;
        say "Active Workflow Jobs:";
        say "-" x 60;
        
        my $minion = $self->app->minion;
        my $jobs = $minion->jobs({
            tasks => ['workflow_executor', 'attendance_check'],
            states => ['inactive', 'active']
        });
        
        unless (@{$jobs->{jobs}}) {
            say "No active workflow jobs";
            return;
        }
        
        printf "%-12s %-20s %-10s\\n", "Job ID", "Workflow", "State";
        printf "%-12s %-20s %-10s\\n", "-" x 12, "-" x 20, "-" x 10;
        
        for my $job (@{$jobs->{jobs}}) {
            my $job_args = $job->{args};
            my $workflow = $job_args->[0]->{workflow_slug} if $job_args && $job_args->[0];
            $workflow //= 'unknown';
            
            printf "%-12s %-20s %-10s\\n",
                $job->{id},
                $workflow,
                $job->{state};
        }
    }
}