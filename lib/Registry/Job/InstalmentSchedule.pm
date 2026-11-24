# ABOUTME: Minion job that creates the Stripe schedule for the instalments after the first.
# ABOUTME: Runs after the webhook's COMMIT; retries look for an earlier run's schedule, the last failure alerts.
use 5.42.0;
use Object::Pad;

class Registry::Job::InstalmentSchedule {
    use Registry::DAO;
    use Registry::DAO::Notification;
    use Registry::DAO::Payment;

    sub register ($class, $app) {
        $app->minion->add_task( instalment_schedule => sub ($job, @args) {
            $class->new->run( $job, @args );
        } );
    }

    # $payment_id is instalment 1, already paid. $slug is the tenant schema it
    # lives in -- payments are tenant-scoped, and a job has no request to infer
    # the tenant from.
    method run ( $job, $payment_id, $slug ) {
        unless ( $payment_id && $slug ) {
            return $job->fail('instalment_schedule needs a payment id and a tenant slug');
        }

        my $dao = $job->app->dao($slug);
        my $payment = Registry::DAO::Payment->find( $dao->db, { id => $payment_id } );

        # A payment that has gone is not a failure to retry. The enrolment may
        # have been cancelled and the row removed between the webhook and here.
        return $job->finish("payment $payment_id is gone") unless $payment;

        # Stripe is reached here, so a failure must be retried rather than
        # swallowed: without the schedule the family pays instalment one and
        # nothing else, which is the defect #425 is about, arrived by a different
        # road. Dying fails the job, and Minion retries it on the attempts the
        # webhook enqueued it with (Controller::Webhooks). A retry looks for a
        # schedule an earlier run made first, and never changes the key.
        my $schedule_id;
        try { $schedule_id = $self->create_for( $dao->db, $payment, $job->retries > 0 ) }
        catch ($e) {
            # Minion counts attempts down on each retry: one left is the last.
            $self->_alert( $job, $dao->db, $payment_id, $slug, $e )
                if $job->info->{attempts} <= 1;
            die $e;
        }

        return $job->finish(
            $schedule_id
                ? "payment $payment_id scheduled as $schedule_id"
                : "payment $payment_id needed no schedule"
        );
    }

    # Separated so it can be tested without a Minion context, as
    # DomainVerification::check_pending_domains is.
    method create_for ( $db, $payment, $look_first = 0 ) {
        return $payment->schedule_remaining_instalments( $db, look_first => $look_first );
    }

    # Both who can act: the tenant's admins, whose family it is, and the
    # platform's operators, who can re-run the job once Stripe recovers.
    method _alert ( $job, $db, $payment_id, $slug, $err ) {
        Registry::DAO::Notification->alert_admins( $db,
            'Instalments could not be scheduled',
            "Registry could not set up the remaining instalments of payment $payment_id "
          . "(tenant $slug) at Stripe, so the family has paid instalment one and will "
          . 'not be charged the rest. Collect them by hand, or ask Registry support '
          . 'to schedule them.',
            { payment_id => $payment_id } );
        $job->app->log->error( "instalment_schedule for payment $payment_id (tenant $slug) "
              . 'failed its last attempt; the rest will not be charged: '
              . ( "$err" =~ s/([^\x20-\x7e])/sprintf '\\x{%x}', ord $1/ger ) );
    }
}
