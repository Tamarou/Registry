# ABOUTME: Minion job that settles paid instalment invoices no webhook recorded, as the Connect webhook would have.
# ABOUTME: Per tenant with a Stripe account, lists each owed schedule's paid invoices and flags any it cannot place.
use 5.42.0;
use Object::Pad;

class Registry::Job::InstalmentReconcile {
    use Registry::Controller::Webhooks;
    use Registry::Service::Stripe;

    sub register ($class, $app) {
        $app->minion->add_task( instalment_reconcile => sub ($job, @args) {
            $class->new->run( $job, @args );
        } );
    }

    # An invoice billed before its schedule was recorded is dropped by the
    # webhook after a day (_settle_connect_event), so the family shows as owing
    # what Stripe collected. Stripe's list is the record: every paid invoice on
    # a schedule with an owed row that no row is bound to is settled here.
    method run ($job) {
        my $app = $job->app;
        my $tenants = $app->dao('registry')->db->query( q{
            SELECT slug, stripe_connect_account_id AS account FROM registry.tenants
             WHERE stripe_connect_account_id IS NOT NULL
        } )->hashes;
        $self->reconcile_tenant( $app, $_ ) for @$tenants;
        return $job->finish;
    }

    method reconcile_tenant ($app, $tenant) {
        my $db = $app->dao( $tenant->{slug} )->db;
        # shortcut: a fully paid set is not checked for a surplus paid invoice;
        # drop the EXISTS if Stripe is ever seen billing past a set's rows.
        my $schedules = $db->query( q{
            SELECT p.stripe_schedule_id FROM payments p
             WHERE p.instalment_seq = 1 AND p.stripe_schedule_id IS NOT NULL
               AND EXISTS ( SELECT 1 FROM payments o
                             WHERE o.stripe_schedule_id = p.stripe_schedule_id
                               AND o.status IN ('pending', 'failed') )
        } )->arrays->flatten;

        my $stripe = Registry::Service::Stripe->from_env->for_account( $tenant->{account} );
        for my $schedule (@$schedules) {
            try { $self->reconcile_schedule( $app, $db, $stripe, $tenant, $schedule ) }
            catch ($e) {
                # One unreachable schedule must not hold up the rest; the next run retries it.
                $app->log->error( "instalment_reconcile: schedule "
                      . _printable($schedule) . " (tenant $tenant->{slug}) failed: "
                      . _printable($e) );
            }
        }
    }

    method reconcile_schedule ($app, $db, $stripe, $tenant, $schedule) {
        my $sub_id = $stripe->retrieve_subscription_schedule($schedule)->{subscription};
        $sub_id = $sub_id->{id} if ref $sub_id eq 'HASH';
        return unless defined $sub_id && !ref $sub_id;    # not started: nothing billed

        # shortcut: first page only (100 invoices, well past any plan's length);
        # page with starting_after if a schedule ever bills more.
        my $invoices = $stripe->list_invoices(
            { subscription => $sub_id, status => 'paid', limit => 100 } )->{data} // [];

        # Oldest first, so each takes the earliest owed row as it would have live.
        for my $invoice ( sort { ( $a->{created} // 0 ) <=> ( $b->{created} // 0 ) } @$invoices ) {
            my $invoice_id = $invoice->{id};
            next unless defined $invoice_id && !ref $invoice_id;
            # Only what the schedule billed, as the webhook decides.
            next unless ( $invoice->{billing_reason} // '' )
                =~ /\Asubscription_(?:create|cycle|update)\z/;
            # shortcut: an invoice bound to a failed row whose paid event was
            # dropped is left failed; settle bound non-completed rows if that shows up.
            next if $self->_bound( $db, $schedule, $invoice_id );

            my $tx = $db->begin;
            Registry::Controller::Webhooks->new( app => $app )->_process_instalment_invoice(
                $db, { type => 'invoice.paid', data => { object => $invoice } }, $schedule );
            $tx->commit;

            next if $self->_bound( $db, $schedule, $invoice_id );
            $app->log->error( "instalment_reconcile: tenant $tenant->{slug} schedule "
                  . _printable($schedule) . ': paid invoice ' . _printable($invoice_id)
                  . ' matches no owed row; Stripe collected it but no payment records it' );
        }
    }

    method _bound ($db, $schedule, $invoice_id) {
        return $db->query( q{
            SELECT 1 FROM payments
             WHERE stripe_schedule_id = ? AND metadata->>'stripe_invoice_id' = ?
        }, $schedule, $invoice_id )->rows;
    }

    sub _printable ($v) { Registry::Controller::Webhooks::_printable($v) }
}
