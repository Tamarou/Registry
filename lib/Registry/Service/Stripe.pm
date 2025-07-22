# ABOUTME: Asynchronous Stripe API service wrapper using Mojo::UserAgent
# ABOUTME: Provides modern Stripe API support with webhook verification and async operations
use 5.40.2;
use experimental qw(signatures try);
use Object::Pad;

class Registry::Service::Stripe {
    use Mojo::UserAgent;
    use Mojo::JSON qw(encode_json decode_json);
    use Digest::SHA qw(hmac_sha256_hex);
    use Carp qw(croak);

    field $ua = Mojo::UserAgent->new;
    field $api_key :param;
    field $api_version :param = '2024-12-18'; # Latest Stripe API version
    field $webhook_secret :param = undef;
    
    # Configure user agent for optimal performance
    ADJUST {
        $ua->max_redirects(3);
        $ua->connect_timeout(10);
        $ua->request_timeout(30);
    }
    
    method _request_async($method, $endpoint, $data = {}) {
        my $url = "https://api.stripe.com/v1/$endpoint";
        my $headers = {
            'Authorization' => "Bearer $api_key",
            'Stripe-Version' => $api_version,
            'User-Agent' => 'Registry/1.0 (https://registry.com)',
        };
        
        my $promise;
        
        if ($method eq 'GET') {
            # For GET requests, put data in query parameters
            my $url_with_params = Mojo::URL->new($url);
            $url_with_params->query($data) if keys %$data;
            $promise = $ua->get_p($url_with_params => $headers);
        } else {
            # For POST/PUT/DELETE, send as form data
            $promise = $ua->build_tx($method => $url => $headers => form => $data)->then(
                sub ($tx) { $ua->start_p($tx) }
            );
        }
        
        return $promise->then(sub ($tx) {
            my $res = $tx->result;
            
            unless ($res->is_success) {
                my $error_body = $res->body;
                my $error_data;
                
                try {
                    $error_data = decode_json($error_body);
                } catch ($e) {
                    croak "Stripe API Error: HTTP " . $res->code . " - " . ($error_body // 'Unknown error');
                }
                
                my $error_msg = $error_data->{error}{message} // 'Unknown Stripe error';
                my $error_type = $error_data->{error}{type} // 'api_error';
                my $error_code = $error_data->{error}{code} // '';
                
                croak "Stripe $error_type: $error_msg" . ($error_code ? " ($error_code)" : '');
            }
            
            return decode_json($res->body);
        });
    }
    
    # Payment Intents API
    method create_payment_intent_async($params) {
        return $self->_request_async('POST', 'payment_intents', $params);
    }
    
    method retrieve_payment_intent_async($intent_id) {
        return $self->_request_async('GET', "payment_intents/$intent_id");
    }
    
    method confirm_payment_intent_async($intent_id, $params = {}) {
        return $self->_request_async('POST', "payment_intents/$intent_id/confirm", $params);
    }
    
    method cancel_payment_intent_async($intent_id) {
        return $self->_request_async('POST', "payment_intents/$intent_id/cancel");
    }
    
    # Setup Intents API (for saved payment methods)
    method create_setup_intent_async($params) {
        return $self->_request_async('POST', 'setup_intents', $params);
    }
    
    method retrieve_setup_intent_async($intent_id) {
        return $self->_request_async('GET', "setup_intents/$intent_id");
    }
    
    method confirm_setup_intent_async($intent_id, $params = {}) {
        return $self->_request_async('POST', "setup_intents/$intent_id/confirm", $params);
    }
    
    # Customers API
    method create_customer_async($params) {
        return $self->_request_async('POST', 'customers', $params);
    }
    
    method retrieve_customer_async($customer_id) {
        return $self->_request_async('GET', "customers/$customer_id");
    }
    
    method update_customer_async($customer_id, $params) {
        return $self->_request_async('POST', "customers/$customer_id", $params);
    }
    
    method delete_customer_async($customer_id) {
        return $self->_request_async('DELETE', "customers/$customer_id");
    }
    
    # Payment Methods API
    method create_payment_method_async($params) {
        return $self->_request_async('POST', 'payment_methods', $params);
    }
    
    method retrieve_payment_method_async($pm_id) {
        return $self->_request_async('GET', "payment_methods/$pm_id");
    }
    
    method attach_payment_method_async($pm_id, $customer_id) {
        return $self->_request_async('POST', "payment_methods/$pm_id/attach", {
            customer => $customer_id
        });
    }
    
    method detach_payment_method_async($pm_id) {
        return $self->_request_async('POST', "payment_methods/$pm_id/detach");
    }
    
    method list_customer_payment_methods_async($customer_id, $type = 'card') {
        return $self->_request_async('GET', 'payment_methods', {
            customer => $customer_id,
            type => $type
        });
    }
    
    # Subscriptions API
    method create_subscription_async($params) {
        return $self->_request_async('POST', 'subscriptions', $params);
    }
    
    method retrieve_subscription_async($subscription_id) {
        return $self->_request_async('GET', "subscriptions/$subscription_id");
    }
    
    method update_subscription_async($subscription_id, $params) {
        return $self->_request_async('POST', "subscriptions/$subscription_id", $params);
    }
    
    method cancel_subscription_async($subscription_id, $params = {}) {
        return $self->_request_async('DELETE', "subscriptions/$subscription_id", $params);
    }
    
    # Refunds API
    method create_refund_async($params) {
        return $self->_request_async('POST', 'refunds', $params);
    }
    
    method retrieve_refund_async($refund_id) {
        return $self->_request_async('GET', "refunds/$refund_id");
    }
    
    # Prices API (for subscriptions)
    method create_price_async($params) {
        return $self->_request_async('POST', 'prices', $params);
    }
    
    method retrieve_price_async($price_id) {
        return $self->_request_async('GET', "prices/$price_id");
    }
    
    method list_prices_async($params = {}) {
        return $self->_request_async('GET', 'prices', $params);
    }
    
    # Products API
    method create_product_async($params) {
        return $self->_request_async('POST', 'products', $params);
    }
    
    method retrieve_product_async($product_id) {
        return $self->_request_async('GET', "products/$product_id");
    }
    
    # Webhook signature verification
    method verify_webhook_signature($payload, $signature_header) {
        croak "Webhook secret not configured" unless $webhook_secret;
        
        # Parse signature header (format: t=timestamp,v1=signature)
        my %signatures;
        for my $pair (split /,/, $signature_header) {
            my ($key, $value) = split /=/, $pair, 2;
            $signatures{$key} = $value;
        }
        
        my $timestamp = $signatures{t} or croak "Invalid signature header: missing timestamp";
        my $signature = $signatures{v1} or croak "Invalid signature header: missing v1 signature";
        
        # Check timestamp (must be within 5 minutes)
        my $current_time = time;
        if (abs($current_time - $timestamp) > 300) {
            croak "Webhook timestamp too old";
        }
        
        # Compute expected signature
        my $signed_payload = "$timestamp.$payload";
        my $expected_signature = hmac_sha256_hex($signed_payload, $webhook_secret);
        
        # Constant-time comparison to prevent timing attacks
        unless ($self->_secure_compare($signature, $expected_signature)) {
            croak "Invalid webhook signature";
        }
        
        return 1;
    }
    
    # Synchronous wrapper methods for backward compatibility
    method create_payment_intent($params) {
        return $self->create_payment_intent_async($params)->wait;
    }
    
    method retrieve_payment_intent($intent_id) {
        return $self->retrieve_payment_intent_async($intent_id)->wait;
    }
    
    method create_refund($params) {
        return $self->create_refund_async($params)->wait;
    }
    
    method create_customer($params) {
        return $self->create_customer_async($params)->wait;
    }
    
    method create_setup_intent($params) {
        return $self->create_setup_intent_async($params)->wait;
    }
    
    method create_subscription($params) {
        return $self->create_subscription_async($params)->wait;
    }
    
    # Helper method for secure string comparison
    method _secure_compare($a, $b) {
        return 0 if length($a) != length($b);
        
        my $result = 0;
        for my $i (0 .. length($a) - 1) {
            $result |= ord(substr($a, $i, 1)) ^ ord(substr($b, $i, 1));
        }
        
        return $result == 0;
    }
    
    # Batch operations for efficiency
    method batch_async($operations) {
        my @promises = map {
            my $op = $_;
            $self->_request_async($op->{method}, $op->{endpoint}, $op->{data} // {});
        } @$operations;
        
        return Mojo::Promise->all(@promises);
    }
    
    # Error handling helpers
    method is_card_error($error) {
        return $error =~ /card_error:/;
    }
    
    method is_rate_limit_error($error) {
        return $error =~ /rate_limit:/;
    }
    
    method is_authentication_error($error) {
        return $error =~ /authentication_error:/;
    }
    
    method is_api_error($error) {
        return $error =~ /api_error:/;
    }
}

1;