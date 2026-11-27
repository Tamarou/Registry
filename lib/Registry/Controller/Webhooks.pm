use 5.42.0;

use Object::Pad;

class Registry::Controller::Webhooks :isa(Registry::Controller) {
    use JSON;
    use Digest::SHA qw(hmac_sha256_hex);
    use Mojo::Promise;
    use Registry::Service::Stripe;
    use Registry::DAO::Workflow;
    use Registry::DAO::Payment;
    use Registry::DAO::Tenant;
    use Registry::DAO::WebhookEvent;
    use Registry::DAO::WorkflowSteps::ApplyStripeDispute;
    use Registry::DAO::WorkflowSteps::ApplyStripeRefund;

    method stripe() {
        my $event = $self->_verified_event('STRIPE_WEBHOOK_SECRET') or return;

        # Process the event
        my $dao = $self->app->dao;

        # One connection for the whole settlement. $dao->db is a single field
        # computed once, so every statement below lands on the same backend --
        # which is what lets the claim and the work share a transaction. A
        # handle acquired anywhere else is a different backend and cannot see
        # this transaction's uncommitted rows or its search_path.
        my $db       = $dao->db;
        my $event_id = $event->{id};

        # Cheap and not authoritative -- the ON CONFLICT claim decides -- but it
        # spares a redelivery of a processed fee refund its Stripe charge read.
        my $seen = $db->select( 'registry.webhook_events', ['id'],
            { stripe_event_id => $event_id } )->hash;

        return $self->_settle_fee_refunded( $db, $event, $seen )
            if ( $event->{type} // '' ) eq 'application_fee.refunded';

        # Events on the platform's own account settle in the registry schema
        # (no slug). A seller's events arrive at stripe_connect, which finds
        # the tenant from event.account, never from metadata.
        $self->render_later;
        try { $self->_settle_event( $dao, $db, $event, $event_id, undef ) }
        catch ($err) {
            # Opening the transaction failed; _settle_event renders its own
            # failures inside it. Nothing claimed, so a 500 asks Stripe to retry.
            $self->app->log->error("Webhook failed before settlement: $err");
            $self->render( status => 500, text => 'Webhook processing failed' );
        }
    }

    # application_fee.refunded: Stripe reports how much of the fee on a
    # seller's charge has gone back, whoever returned it. The fee names the
    # seller's account, which finds the tenant, and the charge, whose payment
    # intent finds the payment Registry stored. The charge is read before the
    # transaction, so the claim never waits on Stripe; a failed read answers
    # 500 unclaimed, so Stripe's redelivery is recorded rather than lost.
    method _settle_fee_refunded ( $db, $event, $seen ) {
        my $fee     = $event->{data}{object} // {};
        my $account = $fee->{account};
        # An exact, bound match, as at stripe_connect.
        my $tenant  = defined $account && !ref $account
            ? Registry::DAO::Tenant->by_connect_account( $db, $account )
            : undef;

        # No tenant to record into, and a redelivery cannot create one.
        unless ($tenant) {
            $self->app->log->warn( "Webhook event $event->{id} (application_fee.refunded) "
                  . "names no tenant's account '" . _printable( $account // '' ) . "'" );
            $self->render( status => 200, text => 'OK (no tenant)' );
            return;
        }

        $self->render_later;
        return (
            $seen
            ? Mojo::Promise->resolve(undef)
            : Registry::Service::Stripe->from_env->for_account($account)
                ->retrieve_charge_async( $fee->{charge} )
          )->then( sub ($charge) {
            my $tx = $db->begin;
            return unless $self->_claim_event( $db, $event );

            try {
                Registry::DAO::Tenant->use_schema_for_transaction( $db, $tenant->{slug} );
                # The highest amount reported wins: a redelivery, or an older
                # event arriving late, never lowers what was recorded.
                $self->app->log->info( "Webhook event $event->{id}: charge "
                      . _printable( $fee->{charge} // '' )
                      . " matched no payment in tenant $tenant->{slug}" )
                    unless Registry::DAO::Payment->record_platform_fee_refunded( $db,
                        $charge->{payment_intent}, $fee->{amount_refunded} );
                Registry::DAO::WebhookEvent->mark_processed( $db, $event->{id} );
                $tx->commit;
            }
            catch ($e) {
                $self->app->log->error("Webhook event $event->{id} failed: $e");
                $self->render( status => 500, text => 'Webhook processing failed' );
                return;
            }
            $self->render( status => 200, text => 'OK' );
          } )->catch( sub ($err) {
            $self->app->log->error("Webhook event $event->{id}: charge lookup failed: $err");
            $self->render( status => 500, text => 'Webhook processing failed' );
          } );
    }

    # The event a delivery carries, once its signature verifies against the
    # secret named by $secret_var. Renders the refusal and returns undef
    # otherwise. Each endpoint has its own secret, so a delivery signed for one
    # never verifies at the other.
    method _verified_event ($secret_var) {
        # The secret is mandatory. Without it, anyone can forge payment
        # confirmations.
        my $payload = $self->req->body;
        my $endpoint_secret = $ENV{$secret_var};

        unless ($endpoint_secret) {
            $self->app->log->error("$secret_var not configured -- rejecting webhook");
            $self->render(status => 500, text => 'Webhook verification not configured');
            return undef;
        }

        my $sig_header = $self->req->headers->header('stripe-signature');
        unless ($sig_header && $self->_verify_stripe_signature($payload, $sig_header, $endpoint_secret)) {
            $self->render(status => 400, text => 'Invalid signature');
            return undef;
        }

        my $event;
        try {
            $event = decode_json($payload);
        }
        catch ($e) {
            $self->render(status => 400, text => 'Invalid JSON');
            return undef;
        }
        return $event;
    }

    # Take the dedup claim on $db, inside the caller's transaction. False, with
    # the duplicate answered, when another delivery already holds it.
    method _claim_event ($db, $event) {
        my $claimed = $db->query(
            q{INSERT INTO registry.webhook_events (stripe_event_id, event_type)
              VALUES (?, ?) ON CONFLICT (stripe_event_id) DO NOTHING},
            $event->{id}, $event->{type}
        )->rows;

        unless ($claimed) {
            $self->app->log->info("Duplicate Stripe webhook event $event->{id} ignored");
            $self->render(status => 200, text => 'OK (duplicate)');
        }
        return $claimed;
    }

    # The Stripe moves applied to entitlements later: refunds, disputes and
    # customer changes made on a tenant's own account. The one list of them.
    use constant STRIPE_MOVES => qr/\A(?:charge\.refunded|charge\.refund\.updated
        |refund\.[\w.]+|charge\.dispute\.[\w.]+|customer\.[\w.]+)\z/x;

    # A payment id, as _intent_account (WorkflowSteps/Payment.pm) accepts one.
    use constant UUID => qr/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i;

    # A seller- or Stripe-written value, made safe to put in our log.
    sub _printable ($v) { "$v" =~ s/([^\x20-\x7e])/sprintf '\\x{%x}', ord $1/ger }

    # The invoice events that can settle or flag a family's instalment.
    use constant INSTALMENT_INVOICE =>
        qr/\Ainvoice\.(?:paid|payment_failed|voided|marked_uncollectible)\z/;

    # Claim a Stripe move and store it with its account, tenant and payload,
    # left unprocessed. Nothing it names is changed here. A failure to store
    # rolls the claim back and answers 500, so Stripe's redelivery is not
    # mistaken for a duplicate.
    method _store_stripe_move ($db, $event, $tenant) {
        my $tx = $db->begin;
        return unless $self->_claim_event( $db, $event );

        try {
            Registry::DAO::WebhookEvent->store_move( $db, $event,
                ( ref $event->{account} ? undef : $event->{account} ),
                ( $tenant ? $tenant->{id} : undef ) );
            $tx->commit;
            $self->app->log->info( "Connect webhook event $event->{id} ($event->{type}) "
                  . ( $tenant ? "for tenant $tenant->{slug}" : 'for no tenant' )
                  . ' stored, not yet applied' );
        }
        catch ($e) {
            $self->app->log->error("Storing Connect webhook event $event->{id} failed: $e");
            $self->render( status => 500, text => 'Webhook processing failed' );
            return;
        }

        $self->_start_stripe_move( $tenant->{slug}, $event ) if $tenant;
        $self->render( status => 200, text => 'OK' );
    }

    # A stored refund or dispute of a payment Registry made in $slug is applied
    # by an entitlement-stripe-move run that the driver continues; nobody waits
    # on it. One whose intent is on none of $slug's payments starts nothing.
    method _start_stripe_move ($slug, $event) {
        my @intents = map { $_->{payment_intent} }
            Registry::DAO::WorkflowSteps::ApplyStripeRefund->refunds($event),
            Registry::DAO::WorkflowSteps::ApplyStripeDispute->disputes($event);
        return unless @intents;
        my $dao = $self->app->dao;
        $self->_enqueue_after_commit( $dao, $slug, sub ($minion) {
            my $tdb = $dao->connect_schema($slug)->db;
            return unless Registry::DAO::Payment->count_with_intents( $tdb, \@intents );
            my $workflow = Registry::DAO::Workflow->find( $tdb, { slug => 'entitlement-stripe-move' } )
                or die "tenant $slug has no entitlement-stripe-move workflow\n";
            my $run = $workflow->new_run( $tdb, { data => { stripe_event_id => $event->{id} } } );
            # Three attempts: the driver marks the run halted only on the last.
            $minion->enqueue( continue_workflow_run =>
                [ { tenant => $slug, run_id => $run->id } ], { attempts => 3 } );
        }, 'entitlement-stripe-move', "event $event->{id}",
           "Stripe event $event->{id} was stored but not applied to entitlements: apply it by hand.",
           { stripe_event_id => $event->{id} } );
    }

    # Events that happened on a connected account. Stripe names that account
    # in the top-level `account`, and that -- not our own metadata -- is what
    # finds the tenant.
    method stripe_connect() {
        my $event = $self->_verified_event('STRIPE_CONNECT_WEBHOOK_SECRET') or return;

        my $db       = $self->app->dao->db;
        my $event_id = $event->{id};
        my $account  = $event->{account};

        # An exact, bound match: an id that only resembles a tenant's names none.
        my $tenant = defined $account && !ref $account
            ? Registry::DAO::Tenant->by_connect_account( $db, $account )
            : undef;

        # No tenant to settle into, and a redelivery cannot create one, so
        # Stripe is told to stop rather than asked to retry. No schema is
        # chosen -- in particular not registry. A money or customer event is
        # still kept, attributed to no tenant, so none is lost before step 5
        # applies them; anything else is not claimed.
        return $self->_store_stripe_move( $db, $event, undef )
            if !$tenant && ( $event->{type} // '' ) =~ STRIPE_MOVES;
        unless ($tenant) {
            $self->app->log->warn( "Connect webhook event $event_id names no tenant's account"
                  . ( defined $account && !ref $account ? " '$account'" : '' ) );
            $self->render( status => 200, text => 'OK (no tenant)' );
            return;
        }
        my $slug = $tenant->{slug};

        # A refund Registry made that Stripe answered pending is settled here;
        # one that succeeds is then also stored and applied as a Stripe move.
        # shortcut: a refund.updated that beats _apply_refund_result's hold is
        # stored unapplied, and charge.refund.updated is never matched; settle
        # those from the stored events if they turn up.
        return $self->_settle_connect_event( $db, $event, $slug, undef )
            if ( $event->{type} // '' ) eq 'refund.updated'
                && $self->_holds_pending_refund( $db, $slug, $event->{data}{object}{id} );

        return $self->_store_stripe_move( $db, $event, $tenant )
            if ( $event->{type} // '' ) =~ STRIPE_MOVES;

        # A sale's completion settles through the same code as the platform
        # endpoint, in the schema the account names.
        if ( $event->{type} eq 'payment_intent.succeeded' ) {
            # Stripe is the source of truth: the account wins over whatever
            # tenant our own metadata names.
            my $named = $event->{data}{object}{metadata}{tenant_slug};
            # The seller wrote $named, so it cannot forge lines in our log.
            $self->app->log->warn( "Connect webhook event $event_id names tenant '"
                  . _printable($named)
                  . "' in metadata but account $account is tenant '$slug'; settling in '$slug'" )
                if defined $named && !ref $named && $named ne $slug;

            $self->render_later;
            return $self->_settle_event( $self->app->dao, $db, $event, $event_id, $slug );
        }

        # An instalment invoice names its subscription, never the schedule
        # behind it (API 2024-12-18.acacia). The schedule is read off the
        # subscription on this account -- Stripe sets that field, the seller
        # cannot -- before the transaction, so the claim never waits on Stripe.
        # A failed lookup answers 500 unclaimed, so Stripe retries.
        # shortcut: reads only the top-level invoice.subscription; when the
        # Connect endpoint's API version moves past acacia, read the new spelling.
        # Only an invoice the schedule billed is an instalment: a seller's own
        # invoice against the subscription (billing_reason manual, ...) is not.
        # subscription_update is the schedule too: the invoice at a phase
        # change, such as the final instalment's own amount. A voided or
        # uncollectible invoice keeps the reason it was billed under.
        my $sub_id = $event->{data}{object}{subscription};
        my $reason = $event->{data}{object}{billing_reason} // '';
        if ( $event->{type} =~ INSTALMENT_INVOICE && $sub_id && !ref $sub_id ) {
            unless ( $reason =~ /\Asubscription_(?:create|cycle|update)\z/ ) {
                # The seller chose the reason by how they raised the invoice, so
                # it is escaped before it reaches our log.
                $self->app->log->warn( "Connect webhook event $event_id: invoice for subscription '"
                      . _printable($sub_id)
                      . "' has billing_reason '"
                      . _printable($reason)
                      . "'; not an instalment" );
                return $self->_settle_connect_event( $db, $event, $slug, undef );
            }
            $self->render_later;
            return Registry::Service::Stripe->from_env->for_account($account)
                ->retrieve_subscription_async( $sub_id, { 'expand[]' => 'schedule' } )
                ->then( sub ($subscription) {
                    $self->_settle_connect_event( $db, $event, $slug, $subscription->{schedule} );
                } )->catch( sub ($err) {
                    $self->app->log->error(
                        "Connect webhook event $event_id: subscription $sub_id lookup failed: $err");
                    $self->render( status => 500, text => 'Webhook processing failed' );
                } );
        }

        return $self->_settle_connect_event( $db, $event, $slug, undef );
    }

    # Claim, work, commit for a Connect event in the tenant's schema. $sched
    # is the schedule object Stripe says an invoice's subscription belongs to,
    # if any; its id is Stripe's, its metadata the seller's.
    method _settle_connect_event ($db, $event, $slug, $sched) {
        my $event_id = $event->{id};
        my $account  = $event->{account};
        my $schedule = ref $sched eq 'HASH' ? $sched->{id} : undef;

        my $tx = $db->begin;
        return unless $self->_claim_event( $db, $event );

        # Set when a refund Registry made settles as succeeded: then it is
        # also a Stripe move, applied to entitlements after the COMMIT.
        my $move;

        try {
            # Transaction-local, as in _settle_event.
            Registry::DAO::Tenant->use_schema_for_transaction( $db, $slug );

            # A family's instalment, billed by the schedule Registry made on
            # this account, so matched in this tenant's schema only. Never
            # tenant billing: that is the platform's own subscriptions.
            if ( $event->{type} =~ INSTALMENT_INVOICE
                    && $self->_invoice_is_instalment($db, $schedule) ) {
                $self->_process_instalment_invoice($db, $event, $schedule);
            }
            # Ours, but billed before schedule_instalments_for committed its
            # rows: unclaimed, so Stripe retries once they are there. Only
            # while the signed event is a day old or less: a seller can name
            # an entitlement whose schedule never comes, and that is not retried.
            elsif ( $event->{type} =~ INSTALMENT_INVOICE
                    && $self->_schedule_not_recorded($db, $sched) ) {
                my $created = $event->{created};
                die "instalment schedule $schedule is not recorded yet\n"
                    if defined $created && !ref $created && $created =~ /\A\d+\z/
                    && time - $created < 24 * 60 * 60;
                $self->app->log->warn( "Connect webhook event $event_id: instalment schedule "
                      . _printable($schedule) . " for entitlement "
                      . _printable( $sched->{metadata}{entitlement_id} )
                      . " is still not recorded after a day; not retried" );
            }
            # The readiness mirror, for the account that sent it and no other:
            # the account named inside the event must be the one Stripe
            # delivered it for, which is the one this tenant row stores.
            elsif ( $event->{type} eq 'account.updated'
                    && ( $event->{data}{object}{id} // '' ) eq $account ) {
                $self->_process_account_updated($db, $event);
            }
            elsif ( $event->{type} eq 'refund.updated' ) {
                $move = ( $self->_process_refund_updated($db, $event) // '' ) eq 'succeeded';
            }
            else {
                $self->app->log->info(
                    "Connect webhook event $event_id ($event->{type}) for tenant $slug not handled");
            }

            # A settled refund is stored as _store_stripe_move stores one,
            # left unapplied for the entitlement-stripe-move run.
            if ($move) { Registry::DAO::WebhookEvent->store_move_for_slug( $db, $event, $account, $slug ) }
            else       { Registry::DAO::WebhookEvent->mark_processed( $db, $event_id ) }
            $tx->commit;
        }
        catch ($e) {
            # The claim rolls back with $tx, so Stripe's retry reprocesses.
            $self->app->log->error("Connect webhook event $event_id failed: $e");
            $self->render( status => 500, text => 'Webhook processing failed' );
            return;
        }

        $self->_start_stripe_move( $slug, $event ) if $move;
        $self->render( status => 200, text => 'OK' );
    }

    # The settlement itself: claim, work, commit. Nothing here reaches the
    # network.
    method _settle_event ($dao, $db, $event, $event_id, $slug) {

        # Claim and work are one transaction on one connection. A failure rolls
        # the claim back with the work, so Stripe's retry re-claims and
        # reprocesses -- no compensating delete, which could not run here anyway
        # once the transaction is aborted.
        my $tx = $db->begin;

        return unless $self->_claim_event( $db, $event );

        # Set inside the transaction, acted on after it: the id of a payment the
        # capacity gate demoted and now owes a refund.
        my $refund_for;

        # Set when a superseded intent was paid: the refund owed, after COMMIT.
        my $superseded;

        # Set when an offer payment completed: the run to continue, after COMMIT.
        my $continue_run;

        try {
            # Transaction-local, so it reverts at COMMIT and cannot ride back
            # into the connection pool the way a session-level setting would.
            Registry::DAO::Tenant->use_schema_for_transaction( $db, $slug )
                if defined $slug;

            # One-time program payment finalized by Stripe (e.g. 3DS/redirect
            # cards confirmed off-site). Idempotent with the parent-return path.
            if ($event->{type} eq 'payment_intent.succeeded') {
                $refund_for = $self->_process_payment_intent_succeeded($db, $event,
                    \$superseded, \$continue_run);
            }
            else {
                # Revenue share bills no tenant by subscription, so tenant
                # billing and anything else unknown is acknowledged, not acted on.
                $self->app->log->info(
                    "Webhook event $event_id (" . _printable( $event->{type} // '' ) . ') not handled');
            }

            # received_at to processed_at is the latency of the money path.
            Registry::DAO::WebhookEvent->mark_processed( $db, $event_id );

            $tx->commit;
        }
        catch ($e) {
            # No claim release here: $tx goes out of scope and rolls the claim
            # back with the work. A delete would also fail -- the transaction is
            # already aborted and rejects every further statement.
            $self->app->log->error("Webhook processing failed: $e");
            $self->render(status => 500, text => 'Webhook processing failed');
            return;
        }

        # Post-COMMIT. Reached only on success, so a refund failure below cannot
        # be confused with a settlement failure above.

        # The run an offer payment was taken for goes on whether or not anyone
        # is there to come back: a job drives it from where it was parked
        # (Job::ContinueWorkflowRun). Queued once, by the delivery that
        # completed the payment.
        if ($continue_run) {
            $self->_enqueue_after_commit( $dao, $slug, sub ($minion) {
                # Three attempts: the driver marks the run halted only on the last.
                $minion->enqueue( continue_workflow_run =>
                    [ { tenant => $slug // 'registry', run_id => $continue_run } ], { attempts => 3 } );
            }, 'continue_workflow_run', "run $continue_run",
               "Workflow run $continue_run was paid for but not continued: continue it by hand.",
               { workflow_run_id => $continue_run } );
        }

        # The refund of a paid superseded intent, in a job for the attempts a
        # Stripe call needs (Job::SupersededRefund). One per intent, as the
        # event that queues it is claimed once.
        if ($superseded) {
            my ( $intent, $payment ) = $superseded->@{qw( intent payment )};
            $self->_enqueue_after_commit( $dao, $slug, sub ($minion) {
                $minion->enqueue(
                    superseded_refund => [ $superseded->@{qw( intent account amount payment )},
                        $slug // 'registry', $superseded->{kind} // () ],
                    { attempts => 10, notes => { $intent => 1 } } );
            }, 'superseded_refund', "intent $intent on payment $payment",
               "Registry is NOT refunding Stripe intent $intent for payment $payment "
             . 'after all: refund it by hand in Stripe.',
               { payment_id => $payment, payment_intent_id => $intent } );
            return $self->render(status => 200, text => 'OK');
        }
        return $self->_settle_owed_refund($dao, $slug, $refund_for) if $refund_for;

        $self->render(status => 200, text => 'OK');
    }

    # After the COMMIT the event is claimed, so a 500 would make Stripe retry
    # into nothing: a job Minion refuses is logged and put in front of a person.
    method _enqueue_after_commit ($dao, $slug, $enqueue, $task, $what, $todo, $metadata) {
        try { $enqueue->( $self->app->minion ) }
        catch ($e) {
            $self->app->log->error( "Webhook: could not queue $task for "
                  . _printable($what) . ' after commit: ' . _printable( $e =~ s/\s+\z//r ) );
            require Registry::DAO::Notification;
            my $tdao = ( $slug && $slug ne 'registry' ) ? $dao->connect_schema($slug) : $dao;
            Registry::DAO::Notification->alert_admins( $tdao->db,
                'A Stripe follow-up was not queued: do it by hand',
                "Registry settled a Stripe event but could not queue its follow-up "
              . "($task). $todo", $metadata );
        }
    }

    # Whether a payment in the tenant's schema holds this refund as pending.
    method _holds_pending_refund ($db, $slug, $refund_id) {
        return 0 unless defined $refund_id && !ref $refund_id;
        return Registry::DAO::Payment->count_holding_pending_refund_in( $db, $slug, $refund_id );
    }

    # Settle the held refund it names, in the settlement transaction; a failed
    # or canceled one alerts staff there too, so the alert commits with it.
    method _process_refund_updated ($db, $event) {
        require Registry::DAO::Payment;
        my $refund = $event->{data}{object};
        my $row = Registry::DAO::Payment->holding_pending_refund( $db, $refund->{id} ) or return;
        my $payment = Registry::DAO::Payment->find( $db, { id => $row->{id} } );
        my $outcome = $payment->settle_pending_refund( $db, $refund ) // return;

        my $what = 'refund ' . _printable( $refund->{id} ) . " on payment $row->{id}";
        if ( $outcome eq 'succeeded' ) {
            $self->app->log->info("Connect webhook event $event->{id}: $what succeeded");
            return $outcome;
        }
        $self->app->log->error( "Connect webhook event $event->{id}: $what is "
              . _printable($outcome) . '; it is still owed' );
        $self->_alert_staff_refund_failed( $db, $row->{id}, $refund );
    }

    method _alert_staff_refund_failed ($db, $payment_id, $refund) {
        require Registry::DAO::Notification;
        Registry::DAO::Notification->alert_admins( $db,
            'A refund did not go through',
            "Stripe refund $refund->{id} for payment $payment_id was "
          . "$refund->{status}, so no money went back. The refund is still "
          . 'owed; issue it again or settle it with the family.',
            { payment_id => $payment_id, refund_id => $refund->{id} } );
    }

    # In the settlement transaction, so the alert commits with the claim or
    # not at all.
    method _alert_staff_superseded_paid ($db, $payment_id, $intent_id) {
        require Registry::DAO::Notification;
        Registry::DAO::Notification->alert_admins( $db,
            'A replaced card payment was charged and is being refunded',
            "Stripe intent $intent_id for payment $payment_id had been "
          . 'replaced by a newer attempt, but it was paid anyway, likely '
          . 'from an old browser tab. Nothing was enrolled from it. '
          . 'Registry is refunding it in full, and will tell you if that fails.',
            { payment_id => $payment_id, payment_intent_id => $intent_id } );
    }

    # In the settlement transaction, so the refusal and its alerts commit
    # with the claim or not at all. The row is failed, never completed: it
    # holds the quote, and Stripe took $charged.
    method _refuse_wrong_amount ($db, $payment, $charged) {
        require Registry::DAO::Notification;
        my ( $took, $quote ) = map { sprintf '$%.2f', $_ / 100 } $charged, $payment->amount_cents;
        $payment->_record_intent_failure_write( $db,
            "Stripe charged $took, not the $quote quoted: refunded in full" );
        my $meta = { payment_id => $payment->id, payment_intent_id => $payment->stripe_payment_intent_id,
            workflow_run_id => $payment->metadata->{workflow_run_id} };
        my $why = sprintf 'Stripe charged %s on intent %s for payment %s, which was quoted at %s. Nothing '
            . 'was booked from it. Registry is refunding the charge in full, and will tell you if that '
            . 'fails. Book it by hand at the right price if the customer still wants it.',
            $took, $payment->stripe_payment_intent_id, $payment->id, $quote;
        Registry::DAO::Notification->alert_admins( $db,
            'A payment for the wrong amount was refused and is being refunded', $why, $meta );
        Registry::DAO::Notification->alert_platform( $db,
            'A payment for the wrong amount was refused and is being refunded', $why, $meta );
        # Told by what the payment was for: a change fee buys a reschedule, not a booking.
        my $fee = ( $payment->metadata->{purpose} // '' ) eq 'change_fee';
        Registry::DAO::Notification->create( $db, {
            user_id  => $payment->user_id, type => 'general', channel => 'email',
            subject  => 'Your payment could not be accepted and is being refunded',
            message  => ( $fee
                ? "You were charged $took for your change fee, but the fee was $quote, so your reschedule "
                  . 'did not happen and your booking is where it was. The change fee is being refunded in full'
                : "You were charged $took, but the price was $quote, so nothing was booked. We are "
                  . 'refunding the charge in full' )
                . '; it can take 5-10 business days to show on your statement.'
                . ( $fee ? ' Please try the reschedule again.' : ' Please book again.' ),
            metadata => $meta,
        } );
    }

    # --- Instalments -------------------------------------------------------

    # Is this invoice one of a family's instalments, rather than a tenant paying
    # us? Both arrive as invoice.paid, and the tenant-billing handler would read
    # a parent's instalment as our own subscription being settled.
    method _invoice_is_instalment ($db, $schedule) {
        return 0 unless $schedule;

        my $row = $db->query(
            'SELECT 1 FROM payments WHERE stripe_schedule_id = ? LIMIT 1',
            $schedule )->hash;
        return $row ? 1 : 0;
    }

    # Does this schedule name a paid child's instalment entitlement still
    # awaiting its schedule? Its metadata is the seller's to edit, so it
    # decides only retry against ignore, never which row is marked. The job
    # runs only once the cart charge is paid, so an unpaid one never gets a
    # schedule; a paid one whose job failed for good never does either, which
    # is why the caller retries only while the event is young.
    method _schedule_not_recorded ($db, $sched) {
        my $entitlement_id = ref $sched eq 'HASH' ? $sched->{metadata}{entitlement_id} : undef;
        return 0 unless defined $entitlement_id && !ref $entitlement_id;

        # Compared as text: the seller's value need not be a uuid.
        return Registry::DAO::Payment->instalment_awaiting_schedule( $db, $entitlement_id ) ? 1 : 0;
    }

    # Mark one instalment of this set paid, or failed.
    #
    # Keyed on the invoice id, which is stored on the row it first marked:
    # Stripe retries an invoice on the same invoice and payment intent, so a
    # retry or a redelivery finds that row again. An invoice not seen before
    # takes the earliest row no invoice has marked -- by position, not amount,
    # since only the last instalment's amount differs. A failed row is never
    # taken by a later invoice: it is its own month, still owed.
    method _process_instalment_invoice ($db, $event, $schedule) {
        my $invoice  = $event->{data}{object} // {};
        my $paid     = $event->{type} eq 'invoice.paid';

        my $intent     = $invoice->{payment_intent};
        my $invoice_id = $invoice->{id};
        unless ( defined $invoice_id && !ref $invoice_id ) {
            $self->app->log->warn("instalment invoice for schedule $schedule has no id");
            return;
        }

        # One invoice at a time per schedule. Two deliveries of one invoice
        # (failed and paid) would otherwise both miss its tag and both take the
        # earliest owed row; waiting here, the second sees the first's tag.
        require Registry::DAO::Payment;
        Registry::DAO::Payment->lock_instalment_set( $db, $schedule );

        my $row = Registry::DAO::Payment->instalment_for_invoice( $db, $schedule, $invoice_id );

        # The status writes below (Payment->close_instalment, complete_instalment
        # and fail_instalment) each carry their legality in the WHERE, from
        # Payment->_legal_predecessors: a completed or refunded row is history
        # to every invoice.

        # Stripe will not charge a voided or uncollectible invoice, so its
        # month stays owed: flagged, where a quiet pending row would hide it.
        # Only the row this invoice already bound; a paid one is history.
        # shortcut: an invoice voided before any event bound it flags nothing
        # (its row stays pending, still on the dashboard); bind on
        # invoice.finalized if that gap shows up in the reconciliation.
        if ( my ($closed) = $event->{type} =~ /^invoice\.(voided|marked_uncollectible)$/ ) {
            return unless $row;
            Registry::DAO::Payment->close_instalment( $db, $row->{id},
                $closed eq 'voided' ? 'The invoice was voided.' : 'The invoice was marked uncollectible.' );
            return;
        }

        $row //= Registry::DAO::Payment->next_unbound_instalment( $db, $schedule ) or do {
            $self->app->log->info(
                "instalment invoice for schedule $schedule matched no owed row");
            return;
        };

        if ($paid) {
            # Zero rows: a redelivery, or a row already refunded.
            Registry::DAO::Payment->complete_instalment( $db, $row->{id}, $intent, $invoice_id ) or return;

            # The fee Stripe took on this instalment, which the invoice reports
            # as an intent does; recorded once, by the delivery that completed it.
            Registry::DAO::Payment->find( $db, { id => $row->{id} } )
                ->record_platform_fee( $db, $invoice );
            return;
        }

        # A failure reported after its retry paid: history, not news. A repeat
        # failure is Stripe's next attempt, so its reason replaces the last.
        return if $row->{status} eq 'completed';

        # With no payment intent no charge was attempted, so nothing failed and
        # the row stays owed -- but it is this invoice's month, so bind it.
        unless ($intent) {
            Registry::DAO::Payment->bind_instalment_invoice( $db, $row->{id}, $invoice_id );
            return;
        }

        # Failed. The enrolment is NOT touched: a child who has been attending
        # for six weeks does not lose their place over an expired card. The debt
        # stands on the row and surfaces on Morgan's dashboard, and she decides --
        # she knows her families. That is the keep_and_flag policy, and it is the
        # default rather than the only option (#425).
        my $why = $invoice->{last_finalization_error}{message}
            // 'The card was declined.';
        Registry::DAO::Payment->fail_instalment( $db, $row->{id}, $why, $intent, $invoice_id );
    }

    # Refund what the capacity gate demoted, after its transaction committed.
    #
    # On a tenant-scoped DAO, not the transaction's handle. The search_path
    # override was transaction-local and is gone by now, so this handle is back
    # on registry -- and settle_refund_increment writes the status itself, inside
    # its own ->then, on whatever handle it was given. Unqualified, that write
    # would hit registry.payments, match no rows, and return quietly while
    # Stripe had already refunded the customer. connect_schema hands back a
    # connection whose search_path Mojo::Pg set when it opened it.
    #
    # Always renders 2xx. A refund failure on an already-committed settlement
    # must not answer Stripe with a 500: the retry would hit the dedup claim and
    # be acknowledged as a duplicate, so the refund would never be retried
    # anyway -- and repeated 500s on successful deliveries are how an endpoint
    # gets disabled. The row stays refund_pending for the runbook to find.
    method _settle_owed_refund ($dao, $slug, $payment_id) {
        my $tdao = ( $slug && $slug ne 'registry' ) ? $dao->connect_schema($slug) : $dao;
        my $tdb  = $tdao->db;

        require Registry::DAO::Payment;
        my $payment = Registry::DAO::Payment->find($tdb, { id => $payment_id });

        unless ($payment) {
            $self->app->log->error(
                "capacity refund: payment $payment_id vanished after commit");
            return $self->render(status => 200, text => 'OK');
        }


        # Started from a resolved promise so a *synchronous* throw becomes a
        # rejection this chain's ->catch can see. refund_async dies before
        # returning a promise in several real ways -- the status guard, a
        # missing intent id, stripe_client refusing a live key or failing SSL
        # init -- and a bare ->catch on the returned promise never sees any of
        # them. The exception escapes the action and Mojolicious renders a 500
        # on an already-committed settlement, which is precisely what the
        # always-2xx rule below exists to prevent.
        # One Stripe call per unsettled increment, each for its own amount under
        # its own key -- never the accumulated balance under a key that changes
        # as the balance grows, which is how one debt got paid twice. Sequenced
        # rather than concurrent so a failure stops the chain with the remaining
        # increments still owed and still retryable.
        # Inside the ->then, not above it. unsettled_refund_increments casts
        # jsonb the runbook now invites operators to hand-edit, so it can throw
        # -- and above the resolve that exception escapes the action, after
        # render_later and after the COMMIT, producing exactly the 500 on an
        # already-committed settlement that the always-2xx rule below exists to
        # prevent.
        #
        # The work queue is the predicate, in both callers. An earlier version
        # gated here on refund_owed_cents while the workflow step gated on the
        # queue; they agree only while the invariant holds, and a migration bug
        # produced precisely the row where they disagreed.
        return Mojo::Promise->resolve->then(sub {
            my $due = $payment->unsettled_refund_increments($tdb);
            return unless $due && @$due;

            my $chain = Mojo::Promise->resolve;
            for my $inc (@$due) {
                $chain = $chain->then(sub {
                    $payment->refund_async($tdb, {
                        amount_cents    => $inc->{cents},
                        reason          => 'requested_by_customer',
                        idempotency_key => $payment->capacity_refund_key($inc->{seq}),
                        # settle_refund_increment owns the status for an increment;
                        # said rather than inferred from the key (#286).
                        increment => 1,
                    })->then(sub ($refund) {
                        # Still owed until refund.updated settles it.
                        return $refund if Registry::DAO::Payment->refund_is_pending($refund);
                        # Settled per increment, so a partial success is kept.
                        # Discharging the whole obligation on one response is
                        # how a debt that grew mid-flight got erased.
                        # A zero-row settle is indistinguishable from success
                        # otherwise: Stripe has paid and the increment is still
                        # due, with nobody told.
                        $payment->settle_refund_increment($tdb, $inc->{seq}, $refund)
                            or $self->app->log->error(
                                "capacity refund: settling increment $inc->{seq} of "
                              . "payment $payment_id matched no row after Stripe paid");
                        return $refund;
                    });
                });
            }
            return $chain;
        })->then(sub {
            $self->render(status => 200, text => 'OK');
        })->catch(sub ($err) {
            # Say whether anything was sent. 'not_sent' is certain -- no
            # request was dispatched, so no money moved -- and it spares the
            # operator the runbook's list-refunds-from-Stripe step, which
            # exists only because the row could not answer that question.
            my $class = Registry::DAO::Payment->classify_refund_failure($err);
            $payment->record_refund_failure( $tdb, $err );

            $self->app->log->error(
                "capacity refund failed for payment $payment_id "
              . "($class, nothing was sent to Stripe): $err")
                if $class eq 'not_sent';
            $self->app->log->error(
                "capacity refund failed for payment $payment_id "
              . "($class, the refund may or may not have been taken): $err")
                if $class ne 'not_sent';
            $self->render(status => 200, text => 'OK');
        });
    }

    # Finalize a one-time program payment when Stripe confirms the intent. This
    # is the safety net for cards finalized off-site (3DS / redirect) where the
    # parent may never return to the success page. finalize_enrollment is
    # idempotent, so this is safe alongside the parent-return callback.
    # $db arrives inside the caller's transaction with search_path already
    # pointing at the tenant, so every unqualified name below resolves there.
    # $superseded, if given, is set when the intent is one this row replaced.
    # $continue_run, if given, is set to the workflow run an offer payment was
    # taken for, when this delivery completed it.
    method _process_payment_intent_succeeded ($db, $event, $superseded = \my $unused,
                                              $continue_run = \my $unused_run) {
        my $intent     = $event->{data}{object} // {};
        my $payment_id = $intent->{metadata}{payment_id};

        # A charge Registry did not make -- a seller's own Terminal or counter
        # sale -- or one this schema has no row for. A retry cannot change
        # that, so it is acknowledged rather than refused.
        my sub ignore ($why, $level = 'info') {
            my $pi = $intent->{id} // 'an intent with no id';
            $self->app->log->$level("payment_intent.succeeded for $pi ignored: $why");
            return undef;
        }
        return ignore('no payment_id in metadata') unless $payment_id;

        # The seller writes metadata on a Connect account, and this is bound
        # into WHERE id = ?: a non-UUID is a database error, so a 500 Stripe
        # redelivers until the shared endpoint is disabled; a hash or array is
        # an SQL::Abstract operator.
        return ignore( "payment_id '" . _printable($payment_id) . "' is not a UUID", 'warn' )
            unless !ref $payment_id && $payment_id =~ UUID;

        require Registry::DAO::Payment;
        # FOR UPDATE: this path carries its own copy of the amount and completed
        # checks rather than calling _apply_intent, so it needs its own lock --
        # locking one site and not the other leaves the two racing each other.
        # Safe as a find-by-id: { for => 'update' } occupies the $order slot and
        # silently drops the default ORDER BY, which is immaterial for a unique
        # key and would not be on a filter that matches more than one row.
        my $payment = Registry::DAO::Payment->find($db, { id => $payment_id },
            { for => 'update' });
        # A tenant's payment_id reaching a schema without it -- the platform
        # endpoint, say -- is not a counter sale, so it is worth a warn.
        return ignore( 'payment ' . _printable($payment_id) . ' not found',
            defined $intent->{metadata}{tenant_slug} ? 'warn' : 'info' )
            unless $payment;

        # Only the intent Registry created settles. The seller owns the Connect
        # account, so they can mint their own succeeded intent carrying our
        # payment_id, our amount and no application fee; metadata proves
        # nothing. Registry stored the id when it created the intent.
        my $stored = $payment->stripe_payment_intent_id;

        # One Registry made for this row and then replaced: a decline's
        # best-effort cancel failed and a stale tab paid it. The money is taken
        # but buys nothing, so nothing settles; staff are told inside this
        # transaction and the caller refunds it after the COMMIT (ruling 7a).
        # The stored intent is never superseded, even if listed: an A-B-A
        # resubmit re-stores A, and the return page settles it.
        my $meta = ref $payment->metadata eq 'HASH' ? $payment->metadata : {};
        if ( defined $intent->{id} && !ref $intent->{id}
                && !( defined $stored && $intent->{id} eq $stored )
                && grep { $_ eq $intent->{id} } @{ $meta->{superseded_intent_ids} // [] } ) {
            $self->_alert_staff_superseded_paid( $db, $payment_id, $intent->{id} );
            $$superseded = { intent => $intent->{id}, account => $meta->{stripe_account_id},
                amount => $intent->{amount}, payment => $payment_id };
            return ignore( "it was superseded on payment $payment_id by "
                  . ( $stored // 'none stored' ) . '; refunding it', 'error' );
        }

        return ignore( "payment $payment_id was created with intent "
              . ( $stored // 'none stored' ) . ', not this one', 'warn' )
            unless defined $stored && defined $intent->{id} && $intent->{id} eq $stored;

        # The intent's captured amount must match the payment row before the
        # enrollment snapshot is granted: a stale intent completing after a
        # cart refresh must not enroll the new cart against the old charge.
        # Dying releases the dedup claim, so Stripe retries and a healed row
        # finalizes on a later delivery. Events without an amount (internal
        # fixtures) pass; real Stripe events always carry one.
        if ( defined $intent->{amount} ) {
            my $row_cents = $payment->amount_cents;
            # An offer payment's amount is its quote, written once when it was
            # owed: a charge for any other amount buys nothing. It is refused,
            # refunded in full after the COMMIT, and the payer, staff and the
            # platform are told (ruling 7b). A retry could not change it.
            if ( $intent->{amount} != $row_cents && $payment->offer_version_id ) {
                $self->_refuse_wrong_amount( $db, $payment, $intent->{amount} );
                $$superseded = { intent => $intent->{id}, account => $meta->{stripe_account_id},
                    amount => $intent->{amount}, payment => $payment_id, kind => 'wrong_amount' };
                return ignore( "it charged $intent->{amount}, not the $row_cents quoted on payment "
                      . "$payment_id; refunding it", 'error' );
            }
            die "payment_intent.succeeded: intent $intent->{id} amount "
              . "$intent->{amount} does not match payment $payment_id "
              . "amount $row_cents\n"
                if $intent->{amount} != $row_cents;
        }

        # "Not completed" is not the same question as "not settled". A refunded
        # or refund_pending row reaching mark_completed here is the double-refund
        # path: re-completed, re-demoted by the capacity gate below, and refunded
        # again. Redelivery makes this reachable without any concurrency, because
        # a retry carries a different event id and the dedup claim lets it past.
        # The write decides, and says so if it refuses. The _money_has_moved
        # test above it and mark_completed's own predicate answer the same
        # question, and agreeing by coincidence is exactly the two-classifiers
        # shape this leg exists to remove -- so the guard is gone and the
        # statement is the authority.
        #
        # payment_method is passed because save() used to carry that column and
        # nothing else writes it.
        #
        # The fee Stripe reports is recorded only by the delivery that completes
        # the row, so a redelivery or a later event cannot overwrite it.
        if ( $payment->mark_completed( $db, $intent->{id}, $intent->{payment_method} ) ) {
            $payment->record_platform_fee( $db, $intent );
            # Only a payment sold under an offer version: a cart's run is
            # finished by the parent, and its enrollment just below.
            $$continue_run = $meta->{workflow_run_id}
                if $payment->offer_version_id && $meta->{workflow_run_id};
        }
        else {
            $self->app->log->info(
                "payment $payment_id not completed from status @{[ $payment->status ]}");
        }

        # Non-zero when the capacity gate demoted someone: the caller refunds
        # after the COMMIT. Returns the payment id rather than the amount so the
        # post-COMMIT step re-reads the committed row instead of trusting a
        # value carried across the transaction boundary.
        $payment->finalize_enrollment($db);

        # Gate on the row's persisted obligation, not on what this pass alone
        # computed. An earlier delivery can have recorded a debt whose refund
        # failed; this pass may demote nobody new and still owe it.
        #
        # NOT because redelivery retries it. Earlier comments here claimed
        # "Stripe's own redelivery becomes the retry, the only automated retry
        # there is" -- that is false and measured false: the dedup claim is on
        # stripe_event_id and commits WITH the settlement, so a redelivery of
        # the same event is refused above before this is reached. Only a
        # DIFFERENT event on the same payment reaches here. Until Leg 3's
        # ProcessRefunds exists, a failed capacity refund waits for the runbook.
        # The runbook says so correctly; this file said the opposite.
        my $settled = Registry::DAO::Payment->find($db, { id => $payment_id });

        # The work queue, not the balance -- the same predicate
        # _settle_owed_refund uses. Round 1 unified the two callers one frame
        # too shallow: this gate decides whether the settle runs at all, and it
        # still read the balance. A row whose balance was zeroed while
        # increments remained due is then invisible to a later event that would
        # otherwise have carried the refund.
        #
        # jsonb_array_length, not unsettled_refund_increments: this runs INSIDE
        # the settlement transaction, and that method casts (e->>'cents')::int
        # over jsonb the runbook lets operators hand-edit. A non-numeric value
        # there would throw here, roll back a captured charge with no
        # enrollments, and take the dedup claim with it -- so every retry
        # reproduces it.
        #
        # A length test still raises on a non-array, so the real guarantee is
        # payments_refund_increments_is_array, which makes that state
        # unrepresentable. This predicate is cheap and cast-free; the constraint
        # is what makes it safe.
        return undef unless $settled;
        my $due = $db->query(
            q{SELECT 1 FROM payments
               WHERE id = ?
                 AND ( refund_owed_cents > 0
                       OR jsonb_array_length(refund_increments) > 0 )},
            $payment_id )->rows;
        return $due ? $payment_id : undef;
    }

    # Connect sends account.updated when a connected account's capabilities
    # change. Mirror charges_enabled/details_submitted onto the tenant so the
    # paid-enrollment readiness gate reflects Stripe's current view.
    method _process_account_updated ($db, $event) {
        my $account = $event->{data}{object} // {};
        my $acct_id = $account->{id} or return;

        # A flag the event leaves out stays as it was: absence is not false.
        my sub flag ($key) { defined $account->{$key} ? ( $account->{$key} ? 1 : 0 ) : undef }
        my $updated = Registry::DAO::Tenant->mirror_connect_readiness( $db, $acct_id,
            flag('charges_enabled'), flag('details_submitted') );
        $self->app->log->info("account.updated for unknown connected account $acct_id")
            unless $updated;
    }

    method _verify_stripe_signature($payload, $sig_header, $endpoint_secret) {
        return 0 unless $sig_header;
        return 0 unless defined $endpoint_secret;

        my @sig_elements = split /,/, $sig_header;
        my ( @v1, $timestamp );

        # v1 accumulates. During endpoint-secret rotation Stripe signs the
        # payload with both the old and the new secret and sends both in one
        # header, so keeping only the last one rejects live confirmations for
        # the whole rotation window -- and repeated 4xx is how Stripe disables
        # an endpoint. Whichever secret this deployment holds must verify,
        # wherever its signature sits in the list.
        for my $element (@sig_elements) {
            my ($key, $value) = split /=/, $element, 2;
            if ($key eq 'v1') {
                push @v1, $value;
            } elsif ($key eq 't') {
                $timestamp = $value;
            }
        }

        return 0 unless @v1;

        # Cap the candidate list. Stripe sends one signature normally and two
        # during an endpoint-secret rotation; anything beyond that is someone
        # else's idea. Uncapped, this loop is a CPU amplifier on the one route
        # that opts out of rate limiting (Middleware/RateLimit.pm's
        # @EXCLUDED_PREFIXES) -- measured at 62x over the single-signature form
        # at Mojo's header ceiling, blocking a worker for the duration.
        return 0 if @v1 > 8;
        # A bare `unless $timestamp` would also reject t=0. Test for presence.
        return 0 unless defined $timestamp && length $timestamp;
        # The header is attacker-controlled, so a non-numeric t must be a quiet
        # rejection rather than an uninitialized-value warning in the log.
        return 0 unless $timestamp =~ /\A[0-9]+\z/;

        # Check timestamp (within 5 minutes)
        my $current_time = time();
        return 0 if abs($current_time - $timestamp) > 300;

        # Verify signature using constant-time comparison to prevent timing attacks
        my $signed_payload = $timestamp . '.' . $payload;
        my $expected_sig = hmac_sha256_hex($signed_payload, $endpoint_secret);

        # Stop at the first match. An earlier version deliberately did not, to
        # avoid leaking through timing which candidate matched -- but the
        # candidates are supplied by whoever sent the header, so there is
        # nothing to leak to them that they do not already know. The
        # non-short-circuit form bought a real DoS against a vacuous threat.
        for my $candidate (@v1) {
            return 1 if _secure_compare( $expected_sig, $candidate );
        }
        return 0;
    }

    sub _secure_compare ($a, $b) {
        return 0 unless defined $a && defined $b;
        return 0 unless length($a) == length($b);
        my $result = 0;
        for my $i (0 .. length($a) - 1) {
            $result |= ord(substr($a, $i, 1)) ^ ord(substr($b, $i, 1));
        }
        return $result == 0;
    }

}