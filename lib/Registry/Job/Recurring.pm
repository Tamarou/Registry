# ABOUTME: The one rule every recurring sweep follows: after a run ends, finished or failed, it queues its next run.
# ABOUTME: Holds each sweep's interval; setup_recurring_jobs seeds each chain through the same rule.
use 5.42.0;

package Registry::Job::Recurring {
    use Carp qw( croak );

    # Minion has no cron, so a sweep recurs only by queueing its successor.
    my %SWEEP = (
        attendance_check     => { delay => 60,   priority => 5 },
        domain_verification  => { delay => 900,  priority => 5 },
        # Above the sweeps: a parent waiting on a confirmation notices sooner
        # than a waitlist offer expiring.
        send_notifications   => { delay => 300,  priority => 7 },
        # Ops can also run it at once: ./registry minion job -e instalment_reconcile
        instalment_reconcile => { delay => 3600, priority => 5 },
        waitlist_expiration  => { delay => 300,  priority => 6 },
        process_waitlist     => { delay => 600,  priority => 6 },
    );

    sub tasks ($class) { sort keys %SWEEP }

    sub interval_for ( $class, $task ) {
        my $sweep = $SWEEP{$task} or croak "No recurring interval configured for task '$task'";
        return $sweep->{delay};
    }

    # Queue $task's next run unless one is already queued, so a restart, a
    # second app process or a manual run never starts a second chain. The
    # guard makes check-then-enqueue atomic across processes; whoever holds it
    # is doing this same enqueue. One attempt: the next run is the retry, and
    # a Minion retry would be a second chain.
    sub enqueue_next ( $class, $app, $task ) {
        my $delay  = $class->interval_for($task);
        my $minion = $app->minion;
        my $guard  = $minion->guard( "recurring:$task", 60 ) or return;
        return if $minion->jobs( { tasks => [$task], states => ['inactive'] } )->total;
        return $minion->enqueue( $task, [], {
            delay    => $delay,
            attempts => 1,
            priority => $SWEEP{$task}{priority},
        } );
    }

    # add_task for a sweep: whatever the run does, dies included, its next
    # run is queued before Minion records the outcome.
    sub add_task ( $class, $app, $task, $cb ) {
        $class->interval_for($task);
        $app->minion->add_task( $task => sub ( $job, @args ) {
            try { $cb->( $job, @args ) }
            catch ($e) {
                $class->enqueue_next( $job->app, $task );
                die $e;
            }
            $class->enqueue_next( $job->app, $task );
        } );
    }
}

1;
