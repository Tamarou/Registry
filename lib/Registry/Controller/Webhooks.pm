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

        # Deduplicate by Stripe event id. Stripe may deliver the same event more
        # than once; claim it atomically so a redelivery is acknowledged with
        # 200 but never processed twice. On a processing failure below we release
        # the claim so Stripe's retry can reprocess the event.
        my $event_id = $event->{id};
        my $claimed = $dao->db->query(
            q{INSERT INTO registry.webhook_events (stripe_event_id, event_type)
              VALUES (?, ?) ON CONFLICT (stripe_event_id) DO NOTHING},
            $event_id, $event->{type}
        )->rows;

        unless ($claimed) {
            $self->app->log->info("Duplicate Stripe webhook event $event_id ignored");
            $self->render(status => 200, text => 'OK (duplicate)');
            return;
        }

        try {
            # One-time program payment finalized by Stripe (e.g. 3DS/redirect
            # cards confirmed off-site). Idempotent with the parent-return path.
            if ($event->{type} eq 'payment_intent.succeeded') {
                $self->_process_payment_intent_succeeded($dao, $event);
            }
            # Mirror connected account capability changes to the tenant row so
            # the paid-enrollment readiness gate reflects Stripe's current view.
            elsif ($event->{type} eq 'account.updated') {
                $self->_process_account_updated($dao, $event);
            }
            else {
                # Handle tenant billing events (existing logic)
                my $subscription_dao = Registry::DAO::Subscription->new(db => $dao);
                $subscription_dao->process_webhook_event(
                    $dao->db,
                    $event->{id},
                    $event->{type},
                    $event->{data}
                );
            }
        }
        catch ($e) {
            # Release the claim so Stripe's retry can reprocess this event.
            $dao->db->delete('registry.webhook_events', { stripe_event_id => $event_id });
            $self->app->log->error("Webhook processing failed: $e");
            $self->render(status => 500, text => 'Webhook processing failed');
            return;
        }

        $self->render(status => 200, text => 'OK');
    }

    # Finalize a one-time program payment when Stripe confirms the intent. This
    # is the safety net for cards finalized off-site (3DS / redirect) where the
    # parent may never return to the success page. finalize_enrollment is
    # idempotent, so this is safe alongside the parent-return callback.
    method _process_payment_intent_succeeded ($dao, $event) {
        my $intent     = $event->{data}{object} // {};
        my $payment_id = $intent->{metadata}{payment_id};
        return unless $payment_id;    # not a Registry one-time payment -- ignore

        # The tenant is resolved from our own snapshotted metadata. The Connect
        # `account` field is absent on destination-charge payment_intent events
        # (they are platform events), so metadata is the source of truth.
        my $slug = $intent->{metadata}{tenant_slug};

        # The payment row lives in the schema the registration ran under. A
        # one-time payment without a tenant slug is a registry-schema payment
        # (platform/test); anything else must resolve, or we fail loudly so
        # Stripe retries rather than silently dropping a paid enrollment.
        my $tdao = ($slug && $slug ne 'registry') ? $dao->connect_schema($slug) : $dao;
        my $tdb  = $tdao->db;

        require Registry::DAO::Payment;
        my $payment = Registry::DAO::Payment->find($tdb, { id => $payment_id });
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

        unless (($payment->status // '') eq 'completed') {
            $payment->update($tdb, {
                status                   => 'completed',
                stripe_payment_intent_id => $intent->{id},
            });
        }

        $payment->finalize_enrollment($tdb);
    }

    # Connect sends account.updated when a connected account's capabilities
    # change. Mirror charges_enabled/details_submitted onto the tenant so the
    # paid-enrollment readiness gate reflects Stripe's current view.
    method _process_account_updated ($dao, $event) {
        my $account = $event->{data}{object} // {};
        my $acct_id = $account->{id} or return;

        my $updated = $dao->db->query(
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