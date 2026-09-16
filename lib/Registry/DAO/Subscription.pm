use 5.42.0;

use Object::Pad;

class Registry::DAO::Subscription :isa(Registry::DAO::Object) {
    use JSON;
    use DateTime;
    use Registry::Service::Stripe;

    field $db :param :reader;

    # Stripe I/O belongs to one class. This DAO used to carry its own
    # Mojo::UserAgent and keep the API pin, the timeouts and the auth header in
    # step with Registry::Service::Stripe's by hand -- the comments said as
    # much, and the pin was a literal here against a configurable field there,
    # so passing api_version to the service would have parted them silently.
    field $stripe :reader;

    ADJUST {
        $stripe = Registry::Service::Stripe->new(
            api_key => $ENV{STRIPE_SECRET_KEY} || die "STRIPE_SECRET_KEY not set"
        );
    }

    method create_customer_async($tenant_data, $profile_data) {
        my %form_data = (
            name => $tenant_data->{name},
            email => $profile_data->{billing_email},
            phone => $profile_data->{billing_phone},
            'metadata[tenant_id]' => $tenant_data->{id},
            'metadata[organization_type]' => $profile_data->{organization_type} // 'education'
        );

        # Add address if provided - handle both JSON string and flat field formats
        if ($profile_data->{billing_address}) {
            my $address;

            # Try to decode as JSON first (new workflow format)
            eval {
                $address = decode_json($profile_data->{billing_address});
            };

            # If that fails, treat it as a simple string and use flat fields (test format)
            if ($@) {
                $address = {
                    line1 => $profile_data->{billing_address},
                    city => $profile_data->{billing_city},
                    state => $profile_data->{billing_state},
                    postal_code => $profile_data->{billing_zip},
                    country => $profile_data->{billing_country} // 'US'
                };
            }

            $form_data{'address[line1]'} = $address->{line1} if $address->{line1};
            $form_data{'address[line2]'} = $address->{line2} if $address->{line2};
            $form_data{'address[city]'} = $address->{city} if $address->{city};
            $form_data{'address[state]'} = $address->{state} if $address->{state};
            $form_data{'address[postal_code]'} = $address->{postal_code} if $address->{postal_code};
            $form_data{'address[country]'} = $address->{country} // 'US';
        }

        return $stripe->create_customer_async( \%form_data )->then(
            sub ($response) {
                # Update tenant with Stripe customer ID
                $db->query(
                    'UPDATE registry.tenants SET stripe_customer_id = ? WHERE id = ?',
                    $response->{id}, $tenant_data->{id}
                );

                return $response;
            }
        );
    }

    method create_subscription_async($tenant_id, $customer_id, $payment_method_id = undef) {
        # Use default configuration for backward compatibility
        my $config = {
            plan_name => 'Registry - After School Program Management',
            monthly_amount => 20000, # $200.00 in cents
            currency => 'usd',
            trial_days => 30,
            description => 'Complete program management solution for after-school organizations'
        };
        
        return $self->create_subscription_with_config_async($customer_id, $payment_method_id, $config, $tenant_id);
    }

    method create_subscription_with_config_async($customer_id, $payment_method_id, $config, $tenant_id = undef) {
        my %form_data = (
            customer => $customer_id,
            'items[0][price_data][currency]' => $config->{currency},
            'items[0][price_data][product_data][name]' => $config->{plan_name},
            'items[0][price_data][product_data][description]' => $config->{description},
            'items[0][price_data][recurring][interval]' => 'month',
            'items[0][price_data][unit_amount]' => $config->{monthly_amount},
            trial_period_days => $config->{trial_days},
            collection_method => 'charge_automatically'
        );

        # Add metadata
        if ($tenant_id) {
            $form_data{'metadata[tenant_id]'} = $tenant_id;
        }

        # Add payment method if provided (for immediate setup)
        if ($payment_method_id) {
            $form_data{default_payment_method} = $payment_method_id;
        }

        return $stripe->create_subscription_async( \%form_data )->then(
            sub ($subscription) {
                # Update tenant with subscription information if tenant_id provided
                if ($tenant_id) {
                    my $trial_ends_at =
                      DateTime->from_epoch( epoch => $subscription->{trial_end} );

                    $db->query(
                        'UPDATE registry.tenants SET stripe_subscription_id = ?, billing_status = ?, trial_ends_at = ?, subscription_started_at = ? WHERE id = ?',
                        $subscription->{id},
                        'trial',
                        $trial_ends_at->iso8601(),
                        DateTime->now->iso8601(),
                        $tenant_id
                    );
                }

                return $subscription;
            }
        );
    }

    method get_customer_async($customer_id) {
        return $stripe->retrieve_customer_async($customer_id);
    }

    method get_subscription_async($subscription_id) {
        return $stripe->retrieve_subscription_async($subscription_id);
    }

    method create_setup_intent_async($customer_id, $options = {}) {
        my %form_data = (
            customer => $customer_id,
            usage => $options->{usage} || 'off_session'
        );

        # Add metadata if provided
        if ($options->{metadata}) {
            for my $key (keys %{$options->{metadata}}) {
                $form_data{"metadata[$key]"} = $options->{metadata}->{$key};
            }
        }

        return $stripe->create_setup_intent_async( \%form_data );
    }

    method get_setup_intent_async($setup_intent_id) {
        return $stripe->retrieve_setup_intent_async($setup_intent_id);
    }

    method update_billing_status($db, $tenant_id, $status, $subscription_data = undef) {
        my @params = ($status);
        my $sql = 'UPDATE registry.tenants SET billing_status = ?';
        
        if ($subscription_data) {
            # Update trial end date if subscription data is provided
            if ($subscription_data->{trial_end}) {
                my $trial_ends_at = DateTime->from_epoch(epoch => $subscription_data->{trial_end});
                $sql .= ', trial_ends_at = ?';
                push @params, $trial_ends_at->iso8601();
            }
        }
        
        $sql .= ' WHERE id = ?';
        push @params, $tenant_id;
        return $db->query($sql, @params);
    }

    method cancel_subscription_async($subscription_id, $at_period_end = 1) {
        my %form_data = (
            at_period_end => $at_period_end ? 'true' : 'false'
        );
        return $stripe->cancel_subscription_async( $subscription_id, \%form_data );
    }

    # $subscription is the invoice's subscription, already fetched from Stripe by
    # the caller. The webhook controller pre-fetches it so the blocking call does
    # not happen inside its settlement transaction; callers that pass nothing get
    # the original behaviour, with the handlers fetching it themselves.
    method process_webhook_event($db, $event_id, $event_type, $event_data, $subscription = undef) {
        # Store webhook event for processing
        my $result = $db->query(
            'INSERT INTO registry.subscription_events (stripe_event_id, event_type, event_data) VALUES (?, ?, ?) ON CONFLICT (stripe_event_id) DO NOTHING RETURNING id',
            $event_id, $event_type, encode_json($event_data)
        );
        
        # Return if event already processed
        return unless $result->rows > 0;
        
        my $event_record_id = $result->hash->{id};
        
        # Process different event types
        eval {
            if ($event_type eq 'customer.subscription.updated') {
                $self->_handle_subscription_updated($db, $event_data);
            }
            elsif ($event_type eq 'customer.subscription.deleted') {
                $self->_handle_subscription_deleted($db, $event_data);
            }
            elsif ($event_type eq 'customer.subscription.trial_will_end') {
                $self->_handle_trial_ending($db, $event_data);
            }
            elsif ($event_type eq 'invoice.payment_failed') {
                $self->_handle_payment_failed($db, $event_data, $subscription);
            }
            elsif ($event_type eq 'invoice.payment_succeeded') {
                $self->_handle_payment_succeeded($db, $event_data, $subscription);
            }
            
            # Mark event as processed
            $db->query(
                'UPDATE registry.subscription_events SET processing_status = ?, processed_at = NOW() WHERE id = ?',
                'processed', $event_record_id
            );
        };
        
        if ($@) {
            # Captured first: $db->query runs an eval internally, which resets
            # $@, so `die $@` below would rethrow Perl's bare "Died" and throw
            # away the diagnostic this path exists to surface.
            my $err = $@;
            warn "DEBUG Subscription: Webhook processing failed: $err";
            # Mark event as failed
            $db->query(
                'UPDATE registry.subscription_events SET processing_status = ? WHERE id = ?',
                'failed', $event_record_id
            );
            die $err;
        }
        
        return 1;
    }

    method _handle_subscription_updated($db, $event_data) {
        my $subscription = $event_data->{object};
        my $tenant_id = $subscription->{metadata}->{tenant_id};
        
        return unless $tenant_id;
        
        # Validate tenant_id is a valid UUID format
        return unless $tenant_id =~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
        
        # Check if tenant exists before trying to update
        my $tenant_exists = $db->query('SELECT 1 FROM registry.tenants WHERE id = ?', $tenant_id)->rows;
        return unless $tenant_exists;
        
        my $status = $subscription->{status};
        $self->update_billing_status($db, $tenant_id, $status, $subscription);
    }

    method _handle_subscription_deleted($db, $event_data) {
        my $subscription = $event_data->{object};
        my $tenant_id = $subscription->{metadata}->{tenant_id};
        
        return unless $tenant_id;
        
        # Validate tenant_id is a valid UUID format
        return unless $tenant_id =~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
        
        # Check if tenant exists before trying to update
        my $tenant_exists = $db->query('SELECT 1 FROM registry.tenants WHERE id = ?', $tenant_id)->rows;
        return unless $tenant_exists;
        
        $self->update_billing_status($db, $tenant_id, 'cancelled');
    }

    method _handle_trial_ending($db, $event_data) {
        my $subscription = $event_data->{object};
        my $tenant_id = $subscription->{metadata}->{tenant_id};
        
        return unless $tenant_id;
        
        # Validate tenant_id is a valid UUID format
        return unless $tenant_id =~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
        
        # Check if tenant exists before trying to update
        my $tenant_exists = $db->query('SELECT 1 FROM registry.tenants WHERE id = ?', $tenant_id)->rows;
        return unless $tenant_exists;
        
        # Could send notification email here
        # For now, just ensure billing status is correct
        $self->update_billing_status($db, $tenant_id, 'trial', $subscription);
    }

    # Newer Stripe API versions moved the subscription id off the invoice's top
    # level into parent.subscription_details.subscription. Which one arrives is
    # decided by the endpoint's API version in the Dashboard, outside this code,
    # so read both rather than assume one.
    method _invoice_subscription_id ($invoice) {
        my $top = $invoice->{subscription};
        return $top if defined $top && length $top;
        return $invoice->{parent}{subscription_details}{subscription};
    }

    method _handle_payment_failed($db, $event_data, $subscription = undef) {
        my $invoice = $event_data->{object};
        my $subscription_id = $self->_invoice_subscription_id($invoice);

        # The subscription arrives already fetched. There is deliberately no
        # fallback lookup here: this runs inside the webhook's settlement
        # transaction, where a blocking Stripe call holds the dedup claim open
        # for the length of the round trip and a concurrent redelivery blocks
        # behind it on the uncommitted claim. The fetch belongs to the caller,
        # before it opens the transaction, and the guard below turns a missing
        # one into a retry rather than a silent commit.

        # Transient and permanent failures need opposite answers, and an earlier
        # version of this guard died on both.
        #
        # Transient -- the invoice names a subscription and the caller could
        # not fetch it. Without this the handler would read an undef tenant_id,
        # fall out of the `return unless`, and let the caller stamp the event
        # processed and COMMIT. The tenant was never moved, permanently,
        # because every retry then hit the dedup claim. Dying releases the
        # claim so Stripe's retry can succeed.
        die "Cannot resolve subscription $subscription_id for invoice event\n"
            if defined $subscription_id
            && length $subscription_id
            && !$subscription;

        # Permanent -- the invoice carries no subscription at all. One-off
        # invoices are real, and no retry makes one grow a subscription. Dying
        # here is a poison pill: ~3 days of 500s, after which Stripe disables
        # the endpoint and payment_intent.succeeded stops arriving, taking the
        # enrollment safety net down with it. Webhooks.pm already codifies that
        # rule for the refund path; this is the same rule.
        unless ($subscription) {
            warn "Invoice event carries no subscription id; ignoring\n";
            return;
        }

        # Resolved, but no tenant stamped on it. Either not ours, or ours with
        # the metadata dropped -- and the second costs money quietly, because a
        # non-paying tenant is never moved to past_due. A retry changes nothing,
        # so this is processed rather than failed, but it is warned about rather
        # than ignored.
        my $tenant_id = $subscription->{metadata}->{tenant_id};
        unless ($tenant_id) {
            warn "Subscription @{[ $subscription->{id} // q{?} ]} has no "
                . "metadata.tenant_id; billing status not updated\n";
            return;
        }

        # The same two guards the three sibling handlers carry. metadata is
        # free-form text an operator can edit in the Dashboard, and a non-UUID
        # value aborts the transaction inside update_billing_status -- another
        # permanent condition answered with an endless retry loop.
        return unless $tenant_id
            =~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
        return unless $db->query(
            'SELECT 1 FROM registry.tenants WHERE id = ?', $tenant_id )->rows;
        $self->update_billing_status($db, $tenant_id, 'past_due');
    }

    method _handle_payment_succeeded($db, $event_data, $subscription = undef) {
        my $invoice = $event_data->{object};
        my $subscription_id = $self->_invoice_subscription_id($invoice);

        # The subscription arrives already fetched. There is deliberately no
        # fallback lookup here: this runs inside the webhook's settlement
        # transaction, where a blocking Stripe call holds the dedup claim open
        # for the length of the round trip and a concurrent redelivery blocks
        # behind it on the uncommitted claim. The fetch belongs to the caller,
        # before it opens the transaction, and the guard below turns a missing
        # one into a retry rather than a silent commit.

        # Transient and permanent failures need opposite answers, and an earlier
        # version of this guard died on both.
        #
        # Transient -- the invoice names a subscription and the caller could
        # not fetch it. Without this the handler would read an undef tenant_id,
        # fall out of the `return unless`, and let the caller stamp the event
        # processed and COMMIT. The tenant was never moved, permanently,
        # because every retry then hit the dedup claim. Dying releases the
        # claim so Stripe's retry can succeed.
        die "Cannot resolve subscription $subscription_id for invoice event\n"
            if defined $subscription_id
            && length $subscription_id
            && !$subscription;

        # Permanent -- the invoice carries no subscription at all. One-off
        # invoices are real, and no retry makes one grow a subscription. Dying
        # here is a poison pill: ~3 days of 500s, after which Stripe disables
        # the endpoint and payment_intent.succeeded stops arriving, taking the
        # enrollment safety net down with it. Webhooks.pm already codifies that
        # rule for the refund path; this is the same rule.
        unless ($subscription) {
            warn "Invoice event carries no subscription id; ignoring\n";
            return;
        }

        # Resolved, but no tenant stamped on it. Either not ours, or ours with
        # the metadata dropped -- and the second costs money quietly, because a
        # non-paying tenant is never moved to past_due. A retry changes nothing,
        # so this is processed rather than failed, but it is warned about rather
        # than ignored.
        my $tenant_id = $subscription->{metadata}->{tenant_id};
        unless ($tenant_id) {
            warn "Subscription @{[ $subscription->{id} // q{?} ]} has no "
                . "metadata.tenant_id; billing status not updated\n";
            return;
        }

        # The same two guards the three sibling handlers carry. metadata is
        # free-form text an operator can edit in the Dashboard, and a non-UUID
        # value aborts the transaction inside update_billing_status -- another
        # permanent condition answered with an endless retry loop.
        return unless $tenant_id
            =~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
        return unless $db->query(
            'SELECT 1 FROM registry.tenants WHERE id = ?', $tenant_id )->rows;
        $self->update_billing_status($db, $tenant_id, 'active');
    }

    method get_tenant_billing_info($tenant_id) {
        return $db->query(
            'SELECT t.*, tp.billing_email, tp.billing_phone, tp.billing_address 
             FROM registry.tenants t 
             LEFT JOIN registry.tenant_profiles tp ON t.id = tp.tenant_id 
             WHERE t.id = ?',
            $tenant_id
        )->hash;
    }

    method is_trial_expired($tenant_id) {
        my $tenant = $self->get_tenant_billing_info($tenant_id);
        return 0 unless $tenant->{trial_ends_at};
        
        # Simple string comparison for now - this is a basic implementation
        my $now = DateTime->now->iso8601() . 'Z';
        my $trial_end = $tenant->{trial_ends_at};
        
        # Convert to comparable format if needed
        if ($trial_end =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/) {
            $trial_end = sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $1, $2, $3, $4, $5, $6);
        }
        
        return $now gt $trial_end;
    }
}