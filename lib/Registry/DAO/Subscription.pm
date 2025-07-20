use 5.34.0;
use experimental 'signatures';
use Object::Pad;

class Registry::DAO::Subscription :isa(Registry::DAO::Object) {
    use Mojo::UserAgent;
    use JSON;
    use DateTime;
    use MIME::Base64;

    field $db :param :reader;
    field $ua :reader;
    field $api_key :reader;
    field $api_base :reader;

    ADJUST {
        $ua = Mojo::UserAgent->new;
        $api_key = $ENV{STRIPE_SECRET_KEY} // 'sk_test_placeholder';
        $api_base = 'https://api.stripe.com/v1';
    }

    method create_customer($tenant_data, $profile_data) {
        my %form_data = (
            name => $tenant_data->{name},
            email => $profile_data->{billing_email},
            phone => $profile_data->{billing_phone},
            'metadata[tenant_id]' => $tenant_data->{id},
            'metadata[organization_type]' => $profile_data->{organization_type} // 'education'
        );

        # Add address if provided
        if ($profile_data->{billing_address}) {
            my $address = decode_json($profile_data->{billing_address});
            $form_data{'address[line1]'} = $address->{line1} if $address->{line1};
            $form_data{'address[line2]'} = $address->{line2} if $address->{line2};
            $form_data{'address[city]'} = $address->{city} if $address->{city};
            $form_data{'address[state]'} = $address->{state} if $address->{state};
            $form_data{'address[postal_code]'} = $address->{postal_code} if $address->{postal_code};
            $form_data{'address[country]'} = $address->{country} // 'US';
        }

        my $response = $self->_stripe_request('POST', '/customers', \%form_data);
        return undef unless $response;
        
        # Update tenant with Stripe customer ID
        $db->query(
            'UPDATE registry.tenants SET stripe_customer_id = ? WHERE id = ?',
            $response->{id}, $tenant_data->{id}
        );

        return $response;
    }

    method _stripe_request($method, $endpoint, $data = {}) {
        my $url = $api_base . $endpoint;
        my $auth = encode_base64($api_key . ':', '');
        
        my $headers = {
            'Authorization' => "Basic $auth",
            'Content-Type' => 'application/x-www-form-urlencoded'
        };
        
        my $tx;
        if ($method eq 'POST') {
            $tx = $ua->post($url, $headers, form => $data);
        } elsif ($method eq 'GET') {
            $tx = $ua->get($url, $headers);
        }
        
        unless ($tx->success) {
            warn "Stripe API error: " . $tx->error->{message} if $tx->error;
            return undef;
        }
        
        return $tx->result->json;
    }

    method create_subscription($tenant_id, $customer_id, $payment_method_id = undef) {
        # Use default configuration for backward compatibility
        my $config = {
            plan_name => 'Registry - After School Program Management',
            monthly_amount => 20000, # $200.00 in cents
            currency => 'usd',
            trial_days => 30,
            description => 'Complete program management solution for after-school organizations'
        };
        
        return $self->create_subscription_with_config($customer_id, $payment_method_id, $config, $tenant_id);
    }

    method create_subscription_with_config($customer_id, $payment_method_id, $config, $tenant_id = undef) {
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

        my $subscription = $self->_stripe_request('POST', '/subscriptions', \%form_data);
        return undef unless $subscription;
        
        # Update tenant with subscription information if tenant_id provided
        if ($tenant_id) {
            my $trial_ends_at = DateTime->from_epoch(epoch => $subscription->{trial_end});
            
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

    method get_customer($customer_id) {
        return $self->_stripe_request('GET', "/customers/$customer_id");
    }

    method get_subscription($subscription_id) {
        return $self->_stripe_request('GET', "/subscriptions/$subscription_id");
    }

    method create_setup_intent($customer_id, $options = {}) {
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

        return $self->_stripe_request('POST', '/setup_intents', \%form_data);
    }

    method get_setup_intent($setup_intent_id) {
        return $self->_stripe_request('GET', "/setup_intents/$setup_intent_id");
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

    method cancel_subscription($subscription_id, $at_period_end = 1) {
        my %form_data = (
            at_period_end => $at_period_end ? 'true' : 'false'
        );
        return $self->_stripe_request('DELETE', "/subscriptions/$subscription_id", \%form_data);
    }

    method process_webhook_event($db, $event_id, $event_type, $event_data) {
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
                $self->_handle_payment_failed($db, $event_data);
            }
            elsif ($event_type eq 'invoice.payment_succeeded') {
                $self->_handle_payment_succeeded($db, $event_data);
            }
            
            # Mark event as processed
            $db->query(
                'UPDATE registry.subscription_events SET processing_status = ?, processed_at = NOW() WHERE id = ?',
                'processed', $event_record_id
            );
        };
        
        if ($@) {
            warn "DEBUG Subscription: Webhook processing failed: $@";
            # Mark event as failed
            $db->query(
                'UPDATE registry.subscription_events SET processing_status = ? WHERE id = ?',
                'failed', $event_record_id
            );
            die $@;
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

    method _handle_payment_failed($db, $event_data) {
        my $invoice = $event_data->{object};
        my $subscription_id = $invoice->{subscription};
        
        # Get subscription to find tenant
        my $subscription = $self->get_subscription($subscription_id);
        my $tenant_id = $subscription->{metadata}->{tenant_id};
        
        return unless $tenant_id;
        
        $self->update_billing_status($db, $tenant_id, 'past_due');
    }

    method _handle_payment_succeeded($db, $event_data) {
        my $invoice = $event_data->{object};
        my $subscription_id = $invoice->{subscription};
        
        # Get subscription to find tenant
        my $subscription = $self->get_subscription($subscription_id);
        my $tenant_id = $subscription->{metadata}->{tenant_id};
        
        return unless $tenant_id;
        
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