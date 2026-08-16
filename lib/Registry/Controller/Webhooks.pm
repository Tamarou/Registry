use 5.42.0;

use Object::Pad;

class Registry::Controller::Webhooks :isa(Registry::Controller) {
    use JSON;
    use Digest::SHA qw(hmac_sha256_hex);

    method stripe() {
        # Verify webhook signature -- STRIPE_WEBHOOK_SECRET is mandatory.
        # Without it, anyone can forge payment confirmations.
        my $payload = $self->req->body;
        my $endpoint_secret = $ENV{STRIPE_WEBHOOK_SECRET};

        unless ($endpoint_secret) {
            $self->app->log->error("STRIPE_WEBHOOK_SECRET not configured -- rejecting webhook");
            $self->render(status => 500, text => 'Webhook verification not configured');
            return;
        }

        my $sig_header = $self->req->headers->header('stripe-signature');
        unless ($sig_header && $self->_verify_stripe_signature($payload, $sig_header, $endpoint_secret)) {
            $self->render(status => 400, text => 'Invalid signature');
            return;
        }
        
        # Parse webhook event
        my $event;
        try {
            $event = decode_json($payload);
        }
        catch ($e) {
            $self->render(status => 400, text => 'Invalid JSON');
            return;
        }
        
        # Process the event
        my $dao = $self->app->dao;

        # One connection for the whole settlement. $dao->db is a single field
        # computed once, so every statement below lands on the same backend --
        # which is what lets the claim and the work share a transaction. A
        # handle acquired anywhere else is a different backend and cannot see
        # this transaction's uncommitted rows or its search_path.
        my $db       = $dao->db;
        my $event_id = $event->{id};

        # Resolve the tenant before the transaction opens. The slug lives in our
        # own snapshotted metadata (the Connect `account` field is absent on
        # destination-charge events, which are platform events), and only
        # payment_intent.succeeded carries one -- account.updated and the
        # subscription branch stay in the registry schema.
        #
        # This lookup IS the validation. set_config accepts a nonexistent schema
        # without complaint and only fails later, at the first unqualified table
        # reference, so an unknown slug has to be refused before it gets there.
        my $slug;
        if ( $event->{type} eq 'payment_intent.succeeded' ) {
            my $raw = $event->{data}{object}{metadata}{tenant_slug};
            $slug = $raw if defined $raw && length $raw && $raw ne 'registry';

            if ( defined $slug
                && !$db->select( 'registry.tenants', ['id'], { slug => $slug } )->hash )
            {
                $self->app->log->error(
                    "Webhook event $event_id names unknown tenant slug '$slug'");
                $self->render( status => 500, text => 'Unknown tenant' );
                return;
            }
        }

        # Anything doable before the transaction happens before the transaction.
        # get_subscription is a blocking Stripe call on a user agent with no
        # request timeout; inside the block it would hold the claim open for the
        # length of a network round trip.
        my $subscription = $self->_prefetch_subscription($dao, $event);

        # Claim and work are one transaction on one connection. A failure rolls
        # the claim back with the work, so Stripe's retry re-claims and
        # reprocesses -- no compensating delete, which could not run here anyway
        # once the transaction is aborted.
        my $tx = $db->begin;

        my $claimed = $db->query(
            q{INSERT INTO registry.webhook_events (stripe_event_id, event_type)
              VALUES (?, ?) ON CONFLICT (stripe_event_id) DO NOTHING},
            $event_id, $event->{type}
        )->rows;

        unless ($claimed) {
            $self->app->log->info("Duplicate Stripe webhook event $event_id ignored");
            $self->render(status => 200, text => 'OK (duplicate)');
            return;
        }

        $self->render_later;

        # Set inside the transaction, acted on after it: the id of a payment the
        # capacity gate demoted and now owes a refund.
        my $refund_for;

        try {
            # Transaction-local, so it reverts at COMMIT and cannot ride back
            # into the connection pool the way a session-level setting would.
            # Bound as a parameter: Postgres validates the GUC rather than
            # splicing it into SQL text.
            $db->query( q{SELECT set_config('search_path', ?, true)}, "$slug, public" )
                if defined $slug;

            # One-time program payment finalized by Stripe (e.g. 3DS/redirect
            # cards confirmed off-site). Idempotent with the parent-return path.
            if ($event->{type} eq 'payment_intent.succeeded') {
                $refund_for = $self->_process_payment_intent_succeeded($db, $event);
            }
            # Mirror connected account capability changes to the tenant row so
            # the paid-enrollment readiness gate reflects Stripe's current view.
            elsif ($event->{type} eq 'account.updated') {
                $self->_process_account_updated($db, $event);
            }
            else {
                # Handle tenant billing events (existing logic)
                my $subscription_dao = Registry::DAO::Subscription->new(db => $dao);
                $subscription_dao->process_webhook_event(
                    $db,
                    $event->{id},
                    $event->{type},
                    $event->{data},
                    $subscription,
                );
            }

            # received_at to processed_at is the latency of the money path.
            $db->query(
                q{UPDATE registry.webhook_events SET processed_at = now()
                  WHERE stripe_event_id = ?}, $event_id
            );

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
        return $self->_settle_owed_refund($dao, $slug, $refund_for) if $refund_for;

        $self->render(status => 200, text => 'OK');
    }

    # Refund what the capacity gate demoted, after its transaction committed.
    #
    # On a tenant-scoped DAO, not the transaction's handle. The search_path
    # override was transaction-local and is gone by now, so this handle is back
    # on registry -- and refund_async writes the refunded status itself, inside
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

        my $owed = ( $payment->metadata // {} )->{refund_owed_cents};
        return $self->render(status => 200, text => 'OK') unless $owed;

        return $payment->refund_async($tdb, {
            amount_cents    => $owed,
            reason          => 'requested_by_customer',
            # Stable per payment, so a redelivery that somehow reaches here
            # cannot refund twice within Stripe's key retention window.
            idempotency_key => "refund:capacity:$payment_id",
        })->then(sub {
            $self->render(status => 200, text => 'OK');
        })->catch(sub ($err) {
            $self->app->log->error(
                "capacity refund failed for payment $payment_id: $err");
            $self->render(status => 200, text => 'OK');
        });
    }

    # Subscription lookups for invoice events are the one blocking Stripe call
    # on this path. Fetch it up front so the settlement transaction never waits
    # on the network; process_webhook_event falls back to fetching it itself
    # when this returns undef, which keeps its other callers working unchanged.
    method _prefetch_subscription ($dao, $event) {
        return undef
            unless $event->{type} eq 'invoice.payment_failed'
            || $event->{type} eq 'invoice.payment_succeeded';

        my $subscription_id = $event->{data}{object}{subscription} or return undef;

        return Registry::DAO::Subscription->new(db => $dao)
            ->get_subscription($subscription_id);
    }

    # Finalize a one-time program payment when Stripe confirms the intent. This
    # is the safety net for cards finalized off-site (3DS / redirect) where the
    # parent may never return to the success page. finalize_enrollment is
    # idempotent, so this is safe alongside the parent-return callback.
    # $db arrives inside the caller's transaction with search_path already
    # pointing at the tenant, so every unqualified name below resolves there.
    method _process_payment_intent_succeeded ($db, $event) {
        my $intent     = $event->{data}{object} // {};
        my $payment_id = $intent->{metadata}{payment_id};
        return unless $payment_id;    # not a Registry one-time payment -- ignore

        my $slug = $intent->{metadata}{tenant_slug};

        require Registry::DAO::Payment;
        # FOR UPDATE: this path carries its own copy of the amount and completed
        # checks rather than calling _apply_intent, so it needs its own lock --
        # locking one site and not the other leaves the two racing each other.
        # Safe as a find-by-id: { for => 'update' } occupies the $order slot and
        # silently drops the default ORDER BY, which is immaterial for a unique
        # key and would not be on a filter that matches more than one row.
        my $payment = Registry::DAO::Payment->find($db, { id => $payment_id },
            { for => 'update' });
        die "payment_intent.succeeded: payment $payment_id not found"
          . ($slug ? " in tenant schema '$slug'" : ' in registry schema') . "\n"
            unless $payment;

        # The intent's captured amount must match the payment row before the
        # enrollment snapshot is granted: a stale intent completing after a
        # cart refresh must not enroll the new cart against the old charge.
        # Dying releases the dedup claim, so Stripe retries and a healed row
        # finalizes on a later delivery. Events without an amount (internal
        # fixtures) pass; real Stripe events always carry one.
        if ( defined $intent->{amount} ) {
            my $row_cents = $payment->amount_cents;
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
        unless ( Registry::DAO::Payment->_money_has_moved( $payment->status ) ) {
            $payment->mark_completed($db, $intent->{id});
        }

        # Non-zero when the capacity gate demoted someone: the caller refunds
        # after the COMMIT. Returns the payment id rather than the amount so the
        # post-COMMIT step re-reads the committed row instead of trusting a
        # value carried across the transaction boundary.
        my $owed = $payment->finalize_enrollment($db);
        return $owed ? $payment_id : undef;
    }

    # Connect sends account.updated when a connected account's capabilities
    # change. Mirror charges_enabled/details_submitted onto the tenant so the
    # paid-enrollment readiness gate reflects Stripe's current view.
    method _process_account_updated ($db, $event) {
        my $account = $event->{data}{object} // {};
        my $acct_id = $account->{id} or return;

        my $updated = $db->query(
            q{UPDATE registry.tenants
              SET stripe_charges_enabled = ?, stripe_details_submitted = ?
              WHERE stripe_connect_account_id = ?},
            ($account->{charges_enabled}   ? 1 : 0),
            ($account->{details_submitted} ? 1 : 0),
            $acct_id,
        )->rows;
        $self->app->log->info("account.updated for unknown connected account $acct_id")
            unless $updated;
    }

    method _verify_stripe_signature($payload, $sig_header, $endpoint_secret) {
        return 0 unless $sig_header;
        return 0 unless defined $endpoint_secret;

        my @sig_elements = split /,/, $sig_header;
        my %sigs;

        for my $element (@sig_elements) {
            my ($key, $value) = split /=/, $element, 2;
            if ($key eq 'v1') {
                $sigs{v1} = $value;
            } elsif ($key eq 't') {
                $sigs{t} = $value;
            }
        }

        return 0 unless $sigs{v1} && $sigs{t};

        # Check timestamp (within 5 minutes)
        my $timestamp = $sigs{t};
        my $current_time = time();
        return 0 if abs($current_time - $timestamp) > 300;

        # Verify signature using constant-time comparison to prevent timing attacks
        my $signed_payload = $timestamp . '.' . $payload;
        my $expected_sig = hmac_sha256_hex($signed_payload, $endpoint_secret);

        return _secure_compare($expected_sig, $sigs{v1});
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