# ABOUTME: Minion job that settles paid instalment invoices no webhook recorded, as the Connect webhook would have.
# ABOUTME: Per tenant with a Stripe account, lists each owed schedule's paid invoices and flags any it cannot place.
use 5.42.0;
use Object::Pad;

class Registry::Job::InstalmentReconcile {
    use Registry::Job::Recurring;
    use Registry::Controller::Webhooks;
    use Registry::Service::Stripe;
    use Registry::DAO::Payment;
    use Registry::DAO::Tenant;

    sub register ($class, $app) {
        Registry::Job::Recurring->add_task( $app, instalment_reconcile => sub ($job, @args) {
            $class->new->run( $job, @args );
        } );
    }

    # An invoice billed before its schedule was recorded is dropped by the
    # webhook after a day (_settle_connect_event), so the family shows as owing
    # what Stripe collected. Stripe's list is the record: every paid invoice on
    # a schedule with an owed row is settled here, on its bound row or the next owed one.
    method run ($job) {
        my $app = $job->app;
        my $tenants = Registry::DAO::Tenant->with_connect_account( $app->dao('registry')->db );
        # One broken tenant must not hold up the rest; it is reported by slug, as the other sweeps do.
        my ( @covered, @skipped );
        for my $tenant (@$tenants) {
            try {
                $self->reconcile_tenant( $app, $tenant );
                push @covered, $tenant->{slug};
            }
            catch ($e) {
                ( my $reason = "$e" ) =~ s/\s+/ /g;
                $app->log->error("instalment_reconcile: tenant $tenant->{slug} failed: $reason");
                push @skipped, { slug => $tenant->{slug}, error => $reason };
            }
        }
        return $job->finish( { tenants_covered => \@covered, tenants_skipped => \@skipped } );
    }

    method reconcile_tenant ($app, $tenant) {
        my $db = $app->dao( $tenant->{slug} )->db;
        # shortcut: a fully paid set is not checked for a surplus paid invoice;
        # drop the EXISTS if Stripe is ever seen billing past a set's rows.
        my $schedules = Registry::DAO::Payment->schedules_with_owed_instalments($db);

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

            # Not the $0 opening period (Payment::instalment_schedule_params).
            next if ( $invoice->{amount_due} // '' ) eq '0';

            # Bound invoices too: payment_failed binds a row before the retry
            # pays, and settling is idempotent (a completed row is not touched).
            my $tx = $db->begin;
            Registry::Controller::Webhooks->new( app => $app )->_process_instalment_invoice(
                $db, { type => 'invoice.paid', data => { object => $invoice } }, $schedule );
            $tx->commit;

            next if Registry::DAO::Payment->instalment_invoice_bound( $db, $schedule, $invoice_id );
            $app->log->error( "instalment_reconcile: tenant $tenant->{slug} schedule "
                  . _printable($schedule) . ': paid invoice ' . _printable($invoice_id)
                  . ' matches no owed row; Stripe collected it but no payment records it' );
        }
    }

    sub _printable ($v) { Registry::Controller::Webhooks::_printable($v) }
}
