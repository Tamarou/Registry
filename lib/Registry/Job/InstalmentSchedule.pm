# ABOUTME: Minion job that creates the Stripe schedule for the instalments after the first.
# ABOUTME: Runs after the webhook's COMMIT, because the card only exists once charge one succeeded.
use 5.42.0;
use Object::Pad;

class Registry::Job::InstalmentSchedule {
    use Registry::DAO;
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
        # road. Minion's own backoff does the retrying.
        my $schedule_id = $self->create_for( $dao->db, $payment );

        return $job->finish(
            $schedule_id
                ? "payment $payment_id scheduled as $schedule_id"
                : "payment $payment_id needed no schedule"
        );
    }

    # Separated so it can be tested without a Minion context, as
    # DomainVerification::check_pending_domains is.
    method create_for ( $db, $payment ) {
        return $payment->schedule_remaining_instalments($db);
    }
}
