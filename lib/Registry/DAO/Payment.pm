package Registry::DAO::Payment;
use 5.40.2;
use warnings;
use experimental 'signatures', 'try', 'builtin';

use Object::Pad;
class Registry::DAO::Payment :isa(Registry::DAO::Object) {

use WebService::Stripe;
use Mojo::JSON qw(encode_json decode_json);

field $user_id :param :reader = undef;
field $amount :param :reader = 0;
field $currency :param :reader = 'USD';
field $status :param :reader = 'pending';
field $stripe_payment_intent_id :param :reader = undef;
field $stripe_payment_method_id :param :reader = undef;
field $metadata :param :reader = {};
field $completed_at :param :reader = undef;
field $error_message :param :reader = undef;

field $_stripe_client = undef;
    
    method table_name { 'registry.payments' }
    
    method stripe_client {
        return $_stripe_client if $_stripe_client;
        
        my $api_key = $ENV{STRIPE_SECRET_KEY} || die "STRIPE_SECRET_KEY not set";
        $_stripe_client = WebService::Stripe->new(
            api_key => $api_key,
            version => '2023-10-16',
        );
        
        return $_stripe_client;
    }
    
    method create_payment_intent ($db, $args = {}) {
        my $description = $args->{description} // 'Registry Program Enrollment';
        my $receipt_email = $args->{receipt_email};
        
        # Create payment intent with Stripe
        my $intent;
        eval {
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
        };
        
        if ($@) {
            $error_message = $@;
            $status = 'failed';
            $self->save($db);
            die "Failed to create payment intent: $@";
        }
        
        # Update payment record with Stripe intent ID
        $stripe_payment_intent_id = $intent->{id};
        $self->save($db);
        
        return {
            client_secret => $intent->{client_secret},
            payment_intent_id => $intent->{id},
        };
    }
    
    method process_payment ($db, $payment_intent_id) {
        # Retrieve payment intent from Stripe
        my $intent;
        eval {
            $intent = $self->stripe_client->retrieve_payment_intent($payment_intent_id);
        };
        
        if ($@) {
            $error_message = $@;
            $status = 'failed';
            $self->save($db);
            return { success => 0, error => $@ };
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
        my $item = {
            payment_id => $self->id,
            enrollment_id => $args->{enrollment_id},
            description => $args->{description} // die "Description required",
            amount => $args->{amount} // die "Amount required",
            quantity => $args->{quantity} // 1,
            metadata => encode_json($args->{metadata} // {}),
        };
        
        $db->insert('registry.payment_items', $item);
    }
    
    method line_items ($db) {
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
        eval {
            $refund = $self->stripe_client->create_refund({
                payment_intent => $stripe_payment_intent_id,
                amount => int($refund_amount * 100),
                reason => $reason,
            });
        };
        
        if ($@) {
            die "Refund failed: $@";
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
    
    method for_user ($class, $db, $user_id) {
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
    
    method calculate_enrollment_total ($class, $db, $enrollment_data) {
        my $total = 0;
        my $items = [];
        
        # Import Session class
        require Registry::DAO::Event;
        
        # Calculate cost for each child-session pair
        for my $child (@{$enrollment_data->{children} // []}) {
            my $child_key = $child->{id} || 0;
            my $session_id = $enrollment_data->{session_selections}->{$child_key} 
                          || $enrollment_data->{session_selections}->{all};
            
            next unless $session_id;
            
            my $session = Registry::DAO::Session->new(id => $session_id)->load($db);
            my $pricing = $session->primary_pricing_plan($db);
            
            if ($pricing) {
                my $price = $pricing->calculate_price($child, $session);
                $total += $price;
                
                push @$items, {
                    description => "$child->{first_name} $child->{last_name} - $session->{name}",
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
}

1;