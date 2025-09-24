use 5.34.0;
use experimental qw(signatures try);
use Object::Pad;

class Registry::Controller::Webhooks :isa(Registry::Controller) {
    use JSON;
    use Digest::SHA qw(hmac_sha256_hex);

    method stripe() {
        # Verify webhook signature
        my $payload = $self->req->body;
        my $sig_header = $self->req->headers->header('stripe-signature');
        my $endpoint_secret = $ENV{STRIPE_WEBHOOK_SECRET};
        
        if ($endpoint_secret && !$self->_verify_stripe_signature($payload, $sig_header, $endpoint_secret)) {
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

        try {
            # Determine if this is an installment payment or tenant billing event
            if ($self->_is_installment_payment_event($event)) {
                $self->_process_installment_payment_event($dao->db, $event);
            } else {
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
            $self->app->log->error("Webhook processing failed: $e");
            $self->render(status => 500, text => 'Webhook processing failed');
            return;
        }
        
        $self->render(status => 200, text => 'OK');
    }

    method _verify_stripe_signature($payload, $sig_header, $endpoint_secret) {
        return 1 unless $endpoint_secret; # Skip verification if no secret configured
        return 0 unless $sig_header; # No signature header provided
        
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
        
        # Verify signature
        my $signed_payload = $timestamp . '.' . $payload;
        my $expected_sig = hmac_sha256_hex($signed_payload, $endpoint_secret);
        
        return $expected_sig eq $sigs{v1};
    }

    method _is_installment_payment_event($event) {
        # Check if this event is related to installment payment subscriptions
        my $event_type = $event->{type};

        return 0 unless $event_type =~ /^(invoice\.paid|invoice\.payment_failed|customer\.subscription\.)$/;

        # Check if the subscription has payment_schedule_id in metadata
        my $subscription_id;
        if ($event_type =~ /^invoice\./) {
            $subscription_id = $event->{data}->{object}->{subscription};
        } elsif ($event_type =~ /^customer\.subscription\./) {
            $subscription_id = $event->{data}->{object}->{id};
        }

        return 0 unless $subscription_id;

        # Look for payment schedule with this subscription ID
        my $dao = $self->app->dao;
        my $schedule = $dao->db->query(
            'SELECT id FROM registry.payment_schedules WHERE stripe_subscription_id = ?',
            $subscription_id
        )->hash;

        return defined $schedule;
    }

    method _process_installment_payment_event($db, $event) {
        my $event_type = $event->{type};
        my $event_data = $event->{data};

        # Import PriceOps classes
        require Registry::PriceOps::ScheduledPayment;

        my $payment_ops = Registry::PriceOps::ScheduledPayment->new;

        if ($event_type eq 'invoice.paid') {
            return $payment_ops->handle_invoice_paid($db, $event_data->{object});
        }
        elsif ($event_type eq 'invoice.payment_failed') {
            return $payment_ops->handle_invoice_payment_failed($db, $event_data->{object});
        }
        elsif ($event_type eq 'customer.subscription.updated') {
            # Handle subscription status changes (active, past_due, etc.)
            return $self->_handle_installment_subscription_updated($db, $event_data->{object});
        }
        elsif ($event_type eq 'customer.subscription.deleted') {
            # Handle subscription cancellation
            return $self->_handle_installment_subscription_cancelled($db, $event_data->{object});
        }

        # Log unhandled event types
        $self->app->log->info("Unhandled installment payment event: $event_type");
    }

    method _handle_installment_subscription_updated($db, $subscription) {
        # Find payment schedule by subscription ID
        my $schedule = $db->query(
            'SELECT * FROM registry.payment_schedules WHERE stripe_subscription_id = ?',
            $subscription->{id}
        )->hash;

        return unless $schedule;

        # Update schedule status based on subscription status
        my $new_status = $subscription->{status} eq 'active' ? 'active'
                       : $subscription->{status} eq 'past_due' ? 'past_due'
                       : $subscription->{status} eq 'canceled' ? 'cancelled'
                       : $schedule->{status}; # Keep existing status

        if ($new_status ne $schedule->{status}) {
            $db->query(
                'UPDATE registry.payment_schedules SET status = ?, updated_at = NOW() WHERE id = ?',
                $new_status, $schedule->{id}
            );
        }
    }

    method _handle_installment_subscription_cancelled($db, $subscription) {
        # Find payment schedule and mark as cancelled
        my $schedule = $db->query(
            'SELECT * FROM registry.payment_schedules WHERE stripe_subscription_id = ?',
            $subscription->{id}
        )->hash;

        return unless $schedule;

        # Mark schedule and all pending payments as cancelled
        $db->query(
            'UPDATE registry.payment_schedules SET status = ?, updated_at = NOW() WHERE id = ?',
            'cancelled', $schedule->{id}
        );

        $db->query(
            'UPDATE registry.scheduled_payments SET status = ?, updated_at = NOW() WHERE payment_schedule_id = ? AND status = ?',
            'cancelled', $schedule->{id}, 'pending'
        );
    }
}