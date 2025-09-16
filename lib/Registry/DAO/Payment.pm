use 5.40.2;
use warnings;
use experimental 'signatures', 'try', 'builtin';

use Object::Pad;
class Registry::DAO::Payment :isa(Registry::DAO::Object) {

use Registry::Service::Stripe;
use Mojo::JSON qw(encode_json decode_json);

field $id :param :reader = undef;
field $user_id :param :reader = undef;
field $amount :param :reader = 0;
field $currency :param :reader = 'USD';
field $status :param :reader = 'pending';
field $stripe_payment_intent_id :param :reader = undef;
field $stripe_payment_method_id :param :reader = undef;
field $metadata :param :reader = {};
field $completed_at :param :reader = undef;
field $error_message :param :reader = undef;
field $created_at :param :reader = undef;
field $updated_at :param :reader = undef;

field $_stripe_client = undef;
    
    ADJUST {
        # Decode JSON metadata if it's a string
        if (defined $metadata && !ref $metadata) {
            try {
                $metadata = decode_json($metadata);
            } catch ($e) {
                $metadata = {};
            }
        }
    }
    
    sub table { 'registry.payments' }
    
    sub create ($class, $db, $data) {
        # Handle JSON encoding for metadata
        if (exists $data->{metadata} && ref $data->{metadata}) {
            $data->{metadata} = { -json => $data->{metadata} };
        }
        
        return $class->SUPER::create($db, $data);
    }
    
    method stripe_client {
        return $_stripe_client if $_stripe_client;
        
        my $api_key = $ENV{STRIPE_SECRET_KEY} || die "STRIPE_SECRET_KEY not set";
        my $webhook_secret = $ENV{STRIPE_WEBHOOK_SECRET};
        
        $_stripe_client = Registry::Service::Stripe->new(
            api_key => $api_key,
            webhook_secret => $webhook_secret,
        );
        
        return $_stripe_client;
    }
    
    method create_payment_intent ($db, $args = {}) {
        my $description = $args->{description} // 'Registry Program Enrollment';
        my $receipt_email = $args->{receipt_email};
        
        # Create payment intent with Stripe
        my $intent;
        try {
            $intent = $self->stripe_client->create_payment_intent({
                amount => int($amount * 100), # Convert to cents
                currency => $currency,
                description => $description,
                receipt_email => $receipt_email,
                metadata => {
                    user_id => $user_id,
                    payment_id => $self->id,
                    %{$metadata},
                },
            });
        }
        catch ($e) {
            $error_message = $e;
            $status = 'failed';
            $self->update($db, {
                error_message => $error_message,
                status => $status
            });
            die "Failed to create payment intent: $e";
        }
        
        # Update payment record with Stripe intent ID
        $stripe_payment_intent_id = $intent->{id};
        $self->update($db, {
            stripe_payment_intent_id => $stripe_payment_intent_id
        });
        
        return {
            client_secret => $intent->{client_secret},
            payment_intent_id => $intent->{id},
        };
    }
    
    method process_payment ($db, $payment_intent_id) {
        # Retrieve payment intent from Stripe
        my $intent;
        try {
            $intent = $self->stripe_client->retrieve_payment_intent($payment_intent_id);
        }
        catch ($e) {
            $error_message = $e;
            $status = 'failed';
            $self->save($db);
            return { success => 0, error => $e };
        }
        
        # Update payment status based on intent status
        if ($intent->{status} eq 'succeeded') {
            $status = 'completed';
            $completed_at = \'NOW()';
            $stripe_payment_method_id = $intent->{payment_method};
            $self->save($db);
            
            return { success => 1, payment => $self };
        } elsif ($intent->{status} eq 'processing') {
            $status = 'processing';
            $self->save($db);
            
            return { success => 0, processing => 1 };
        } else {
            $status = 'failed';
            $error_message = $intent->{last_payment_error}->{message} // 'Payment failed';
            $self->save($db);
            
            return { success => 0, error => $error_message };
        }
    }
    
    method add_line_item ($db, $args) {
        $db = $db->db if $db isa Registry::DAO;
        
        die "Description required" unless defined $args->{description};
        die "Amount required" unless defined $args->{amount};
        
        my $item = {
            payment_id => $self->id,
            enrollment_id => $args->{enrollment_id},
            description => $args->{description},
            amount => $args->{amount},
            quantity => $args->{quantity} // 1,
            metadata => encode_json($args->{metadata} // {}),
        };
        
        $db->insert('registry.payment_items', $item);
    }
    
    method line_items ($db) {
        $db = $db->db if $db isa Registry::DAO;
        my $items = $db->select('registry.payment_items', '*', { payment_id => $self->id })->hashes;
        
        # Decode metadata for each item
        for my $item (@$items) {
            $item->{metadata} = decode_json($item->{metadata}) if $item->{metadata};
        }
        
        return $items;
    }
    
    method refund ($db, $args = {}) {
        die "Cannot refund non-completed payment" unless $status eq 'completed';
        die "No payment intent to refund" unless $stripe_payment_intent_id;
        
        my $refund_amount = $args->{amount} // $amount;
        my $reason = $args->{reason} // 'requested_by_customer';
        
        my $refund;
        try {
            $refund = $self->stripe_client->create_refund({
                payment_intent => $stripe_payment_intent_id,
                amount => int($refund_amount * 100),
                reason => $reason,
            });
        }
        catch ($e) {
            die "Refund failed: $e";
        }
        
        # Update payment status
        if ($refund_amount >= $amount) {
            $status = 'refunded';
        } else {
            $status = 'partially_refunded';
        }
        
        # Update metadata to track refund
        $metadata->{refund_id} = $refund->{id};
        $metadata->{refund_amount} = $refund_amount;
        $metadata->{refund_reason} = $reason;
        
        $self->save($db);
        
        return $refund;
    }
    
    sub for_user ($class, $db, $user_id) {
        $db = $db->db if $db isa Registry::DAO;
        my $payments = $db->select(
            'registry.payments',
            '*',
            { user_id => $user_id },
            { order_by => { -desc => 'created_at' } }
        )->hashes;
        
        return [
            map { $class->new(%$_) } @$payments
        ];
    }
    
    sub calculate_enrollment_total ($class, $db, $enrollment_data) {
        my $total = 0;
        my $items = [];
        
        # Import Session class
        require Registry::DAO::Session;
        
        # Calculate cost for each child-session pair
        for my $child (@{$enrollment_data->{children} // []}) {
            my $child_key = $child->{id} || 0;
            my $session_id = $enrollment_data->{session_selections}->{$child_key} 
                          || $enrollment_data->{session_selections}->{all};
            
            next unless $session_id;
            
            my $session = Registry::DAO::Session->find($db, { id => $session_id });
            next unless $session;
            
            my $pricing_plans = $session->pricing_plans($db);
            next unless $pricing_plans && @$pricing_plans;
            
            # Use the first pricing plan or find the best price
            my $pricing = $pricing_plans->[0];
            my $price = $pricing->calculate_price({
                child_count => 1,
                date => time(),
                %$child
            });
            
            if (defined $price) {
                $total += $price;
                
                push @$items, {
                    description => "$child->{first_name} $child->{last_name} - " . $session->name,
                    amount => $price,
                    metadata => {
                        child_id => $child->{id},
                        session_id => $session_id,
                    }
                };
            }
        }
        
        return {
            total => $total,
            items => $items,
        };
    }
    
    # Async payment methods for better performance
    method create_payment_intent_async ($db, $args = {}) {
        my $description = $args->{description} // 'Registry Program Enrollment';
        my $receipt_email = $args->{receipt_email};
        
        return $self->stripe_client->create_payment_intent_async({
            amount => int($amount * 100), # Convert to cents
            currency => $currency,
            description => $description,
            receipt_email => $receipt_email,
            metadata => {
                user_id => $user_id,
                payment_id => $self->id,
                %{$metadata},
            },
        })->then(sub ($intent) {
            # Update payment record with Stripe intent ID
            $stripe_payment_intent_id = $intent->{id};
            $self->save($db);
            return $intent;
        })->catch(sub ($error) {
            $error_message = $error;
            $status = 'failed';
            $self->save($db);
            die "Failed to create payment intent: $error";
        });
    }
    
    method process_payment_async ($db, $payment_intent_id) {
        return $self->stripe_client->retrieve_payment_intent_async($payment_intent_id)
            ->then(sub ($intent) {
                # Update payment status based on intent status
                if ($intent->{status} eq 'succeeded') {
                    $status = 'completed';
                    $completed_at = \'NOW()';
                } elsif ($intent->{status} eq 'processing') {
                    $status = 'processing';
                } elsif ($intent->{status} eq 'requires_payment_method') {
                    $status = 'failed';
                    $error_message = 'Payment method required';
                } else {
                    $status = 'failed';
                    $error_message = 'Payment failed with status: ' . $intent->{status};
                }
                
                $self->save($db);
                
                return { 
                    success => $status eq 'completed' ? 1 : 0, 
                    status => $status,
                    intent => $intent 
                };
            })
            ->catch(sub ($error) {
                $error_message = $error;
                $status = 'failed';
                $self->save($db);
                return { success => 0, error => $error };
            });
    }
    
    method refund_async ($db, $args = {}) {
        die "Payment must be completed before refunding" unless $status eq 'completed';
        die "No Stripe payment intent ID" unless $stripe_payment_intent_id;
        
        my $refund_amount = $args->{amount} // $amount;
        my $reason = $args->{reason} // 'requested_by_customer';
        
        return $self->stripe_client->create_refund_async({
            payment_intent => $stripe_payment_intent_id,
            amount => int($refund_amount * 100),
            reason => $reason,
        })->then(sub ($refund) {
            # Update payment status
            if ($refund_amount >= $amount) {
                $status = 'refunded';
            } else {
                $status = 'partially_refunded';
            }
            
            # Update metadata to track refund
            $metadata->{refund_id} = $refund->{id};
            $metadata->{refund_amount} = $refund_amount;
            $metadata->{refund_reason} = $reason;
            
            $self->save($db);
            return $refund;
        })->catch(sub ($error) {
            die "Refund failed: $error";
        });
    }
}

1;