# ABOUTME: Minion jobs that create, and cancel, the Stripe schedule for one child's instalments after the first.
# ABOUTME: Run after checkout's COMMIT, keyed by entitlement and retried; the last failure alerts the studio's admins.
use 5.42.0;
use Object::Pad;

class Registry::Job::InstalmentSchedule {
    use Registry::DAO;
    use Registry::DAO::Entitlement;
    use Registry::DAO::Notification;
    use Registry::DAO::Payment;

    # What each task does to an entitlement's schedule, and what its admins
    # are told when the last attempt fails.
    my %TASK = (
        instalment_schedule => {
            act     => 'schedule_instalments_for',
            done    => 'scheduled as',
            none    => 'has no instalments to schedule',
            subject => 'Instalments could not be scheduled',
            told    => 'Registry could not set up the remaining instalments of entitlement %s '
                     . '(tenant %s) at Stripe, so the family has paid instalment one and will '
                     . 'not be charged the rest. Collect them by hand, or ask Registry support '
                     . 'to schedule them.',
        },
        cancel_instalment_schedule => {
            act     => 'cancel_instalment_schedule',
            done    => 'cancelled',
            none    => 'had no instalment schedule to cancel',
            subject => 'Instalments could not be cancelled',
            told    => 'Registry could not cancel the remaining instalments of entitlement %s '
                     . '(tenant %s) at Stripe, so the family may still be charged for them. '
                     . "Cancel the schedule in the studio's Stripe dashboard, or ask Registry "
                     . 'support to cancel it.',
        },
    );

    sub register ($class, $app) {
        for my $task ( keys %TASK ) {
            $app->minion->add_task( $task => sub ($job, @args) {
                $class->new->run( $job, $task, @args );
            } );
        }
    }

    # Queues $task for $entitlement_id in tenant $slug. Ten attempts on
    # Minion's default backoff (retries**4 + 15 seconds) is about two and a
    # half hours: past a Stripe outage or a deploy restart, and inside the
    # 24 hours Stripe keeps the job's Idempotency-Keys. One job per
    # entitlement and task: a second ask finds the first still waiting and
    # adds nothing. Two asks at the same instant can still queue two, which
    # is harmless: each run finds what the other did.
    sub enqueue ( $class, $minion, $task, $entitlement_id, $slug ) {
        return if $minion->jobs( {
            tasks  => [$task],
            notes  => [$entitlement_id],
            states => [ 'inactive', 'active' ],
        } )->total;
        return $minion->enqueue( $task => [ $entitlement_id, $slug ],
            { attempts => 10, notes => { $entitlement_id => 1 } } );
    }

    # $entitlement_id was made by a paid cart charge. $slug is the tenant
    # schema it lives in -- a job has no request to infer the tenant from.
    method run ( $job, $task, $entitlement_id, $slug ) {
        unless ( $entitlement_id && $slug ) {
            return $job->fail("$task needs an entitlement id and a tenant slug");
        }

        my $dao = $job->app->dao($slug);
        my $entitlement = Registry::DAO::Entitlement->find( $dao->db, { id => $entitlement_id } );
        return $job->finish("entitlement $entitlement_id is gone") unless $entitlement;

        # Stripe is reached here, so a failure must be retried rather than
        # swallowed: dying fails the job, and Minion retries it on the attempts
        # enqueue gave it. Every run looks for what an earlier one did first,
        # and never changes the key.
        my $schedule_id;
        try { $schedule_id = $self->act_on( $dao->db, $entitlement, $TASK{$task}{act} ) }
        catch ($e) {
            # Minion counts attempts down on each retry: one left is the last.
            $self->_alert( $job, $dao->db, $task, $entitlement_id, $slug, $e )
                if $job->info->{attempts} <= 1;
            die $e;
        }

        return $job->finish(
            $schedule_id
                ? "entitlement $entitlement_id $TASK{$task}{done} $schedule_id"
                : "entitlement $entitlement_id $TASK{$task}{none}"
        );
    }

    # Separated so it can be tested without a Minion context, as
    # DomainVerification::check_pending_domains is.
    method create_for ( $db, $entitlement ) {
        return $self->act_on( $db, $entitlement, 'schedule_instalments_for' );
    }

    method act_on ( $db, $entitlement, $act ) {
        my $payment = $entitlement->payment($db)
            or die 'entitlement ' . $entitlement->id . " was made by no payment\n";
        return $payment->$act( $db, $entitlement );
    }

    # Both who can act: the tenant's admins, whose family it is, and the
    # platform's operators, who can re-run the job once Stripe recovers.
    method _alert ( $job, $db, $task, $entitlement_id, $slug, $err ) {
        Registry::DAO::Notification->alert_admins( $db, $TASK{$task}{subject},
            sprintf( $TASK{$task}{told}, $entitlement_id, $slug ),
            { entitlement_id => $entitlement_id } );
        $job->app->log->error( "$task for entitlement $entitlement_id (tenant $slug) "
              . 'failed its last attempt: '
              . ( "$err" =~ s/([^\x20-\x7e])/sprintf '\\x{%x}', ord $1/ger ) );
    }
}
