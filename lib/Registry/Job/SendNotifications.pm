# ABOUTME: Sends queued email notifications. Nothing drained the queue, so none had ever been sent.
# ABOUTME: Tenant-aware, like every other sweep: notifications live in per-tenant schemas.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::Job::SendNotifications {

    sub register ($class, $app) {
        $app->minion->add_task( send_notifications => sub ($job, @args) {
            $class->perform( $job, @args );
        } );
    }

    # Notification->create writes a row and returns. Nothing sent it: no
    # ->send call on the enrollment path, no sweep of sent_at IS NULL, and no
    # task of any kind. Notification.pm says "Queue exactly one
    # enrollment_confirmation per ENROLMENT" and Payment.pm says "the email can
    # be retried or re-sent later", so a drainer was always the intent -- it was
    # simply never written, and every confirmation ever queued is still sitting
    # there unsent (#421).
    #
    # A job rather than an inline send, because the two things that queue these
    # -- ensure_enrollment_confirmation and Waitlist->join_items -- are both
    # reached from payment settlement, and a blocking network call there is
    # #284: inside a running IOLoop it can never settle. Minion also gives the
    # retries Payment.pm's comment assumed somebody had.
    sub perform ( $class, $job, $slug = undef ) {
        my $app = $job->app;
        my $log = $app->log;

        try {
            my $dao = $app->dao;

            my $result = $slug
                ? { scope => 'tenant', slug => $slug,
                    %{ $class->send_for_tenant( $dao, $slug, $log ) } }
                : { scope => 'all_tenants',
                    %{ $class->send_all_tenants( $dao, $log ) } };

            $job->finish($result);
        }
        catch ($e) {
            $log->error("SendNotifications job failed: $e");
            $job->fail("Sending notifications failed: $e");
        }
    }

    # One query per tenant schema, the same shape as the other sweeps:
    # notifications are unqualified in Registry::DAO::Notification, so they
    # resolve through the tenant search_path and live per tenant.
    sub send_all_tenants ( $class, $dao, $log ) {
        require Registry::DAO::Tenant;

        my $tenants = Registry::DAO::Tenant->get_all_tenant_schemas( $dao->db );

        # Declared separately: in a list assignment the first array slurps
        # the whole right-hand side.
        my @covered;
        my @skipped;
        my $sent   = 0;
        my $failed = 0;
        for my $tenant (@$tenants) {
            my $slug = $tenant->{slug};

            try {
                my $counts = $class->send_for_tenant( $dao, $slug, $log );
                $sent   += $counts->{sent};
                $failed += $counts->{failed};
                push @covered, $slug;
            }
            catch ($e) {
                # Carried out with the slug, not just logged. A sweep built to
                # survive a bad tenant reports success identically whether it
                # skipped none or half the fleet unless it says which (#470).
                my $reason = "$e";
                $reason =~ s/\s+/ /g;
                $log->error("SendNotifications failed for tenant $slug: $reason");
                push @skipped, { slug => $slug, error => $reason };
            }
        }

        return {
            tenants_covered => \@covered,
            tenants_skipped => \@skipped,
            sent            => $sent,
            failed          => $failed,
        };
    }

    sub send_for_tenant ( $class, $dao, $slug, $log ) {
        require Registry::DAO::Notification;

        # registry carries the platform's own notifications -- a tenant signing
        # up gets email verification and magic links there -- so unlike the
        # waitlist sweeps it is NOT skipped.
        my $tenant_dao = $slug eq 'registry' ? $dao : $dao->connect_schema($slug);
        my $db         = $tenant_dao->db;

        # Oldest first, so a backlog drains in the order it was promised.
        # Bounded per run: a first run against a long-accumulated queue should
        # not hold a worker for an unbounded time, and the next run takes the
        # rest.
        #
        # send_email stamps failed_at and a reason rather than throwing, and
        # leaves sent_at NULL -- so a bare `sent_at IS NULL` would retry a
        # permanently bad address on every run, for ever, warning each time.
        # Retried after an hour so a Postmark blip or a transport outage
        # recovers on its own, and abandoned after three days so a dead address
        # stops costing anything. An abandoned row keeps failed_at and
        # failure_reason, so it is still answerable rather than merely quiet.
        my $rows = $db->query( <<~'SQL' )->expand->hashes->to_array;
            SELECT * FROM notifications
             WHERE channel = 'email'
               AND sent_at IS NULL
               AND created_at > now() - interval '3 days'
               AND ( failed_at IS NULL
                     OR failed_at < now() - interval '1 hour' )
             ORDER BY created_at
             LIMIT 200
            SQL

        my ( $sent, $failed ) = ( 0, 0 );
        for my $row (@$rows) {
            my $notification = Registry::DAO::Notification->new(%$row);

            # Per notification, not per tenant. One address that bounces must
            # not strand every other parent's mail behind it.
            #
            # send_email RETURNS 0 on failure rather than throwing -- it records
            # failed_at itself and warns -- so the count turns on the return
            # value. The try is a backstop for anything that escapes it.
            try {
                $notification->send_email($db) ? $sent++ : $failed++;
            }
            catch ($e) {
                my $reason = "$e";
                $reason =~ s/\s+/ /g;
                $log->error( "SendNotifications: notification $row->{id} "
                           . "for tenant $slug failed: $reason" );
                $failed++;
            }
        }

        return { sent => $sent, failed => $failed };
    }
}
