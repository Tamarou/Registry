use 5.42.0;
use warnings;


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

    # Convert a dollar amount to integer cents for Stripe API calls.
    sub _to_cents ($dollars) { int($dollars * 100) }

    # Flatten canonical + caller metadata into Stripe bracket-notation pairs.
    # Stripe metadata values must be plain strings, so refs are dropped; the DB
    # metadata column keeps the full structure. Sorted for deterministic param
    # order (no API significance; keeps tests and request logs stable).
    sub _stripe_metadata_params ($user_id, $payment_id, $metadata) {
        my %m = (
            user_id    => $user_id,
            payment_id => $payment_id,
            ( ref $metadata eq 'HASH'
                ? ( map { $_ => $metadata->{$_} }
                    grep { defined $metadata->{$_} && !ref $metadata->{$_} }
                    keys %$metadata )
                : () ),
        );
        return map { ( "metadata[$_]" => $m{$_} ) } sort keys %m;
    }

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

        # Safety guard: a live key (sk_live_) must never be used outside
        # production. Development and test environments routinely inherit a live
        # key from the shell, and using it would hit the real Stripe API and can
        # create real charges. Require MOJO_MODE=production to opt in.
        if ($api_key =~ /^sk_live_/ && ($ENV{MOJO_MODE} // '') ne 'production') {
            die "Refusing to use a live Stripe key (sk_live_) outside production "
              . "(MOJO_MODE=" . ($ENV{MOJO_MODE} // 'unset') . "); "
              . "set a Stripe test key (sk_test_) for development and tests.\n";
        }

        # Handle SSL requirement gracefully in test environments
        eval {
            $_stripe_client = Registry::Service::Stripe->new(
                api_key => $api_key,
                webhook_secret => $webhook_secret,
            );
        };

        if ($@) {
            # If SSL or other requirements fail, re-throw with a clear message
            die "Stripe client initialization failed: $@";
        }

        return $_stripe_client;
    }
    
    method create_payment_intent ($db, $args = {}) {
        my $description = $args->{description} // 'Registry Program Enrollment';
        my $receipt_email = $args->{receipt_email};
        
        # Create payment intent with Stripe
        my $intent;
        try {
            # Stripe's API is form-encoded; nested hashes must be flattened to
            # bracket notation (metadata[key]=value). Mojo's form generator
            # would otherwise turn a nested hashref into a bogus multipart
            # upload and the metadata would never reach Stripe. Metadata
            # values must be strings, so refs (e.g. enrollment_items) are
            # snapshotted only in the DB metadata column, not sent to Stripe.
            $intent = $self->stripe_client->create_payment_intent({
                amount        => _to_cents($amount),
                currency      => $currency,
                description   => $description,
                receipt_email => $receipt_email,
                _stripe_metadata_params($user_id, $self->id, $metadata),
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
    
    # Idempotently create the paid enrollments and queue their confirmation
    # emails. Safe to call from both the parent-return callback and the
    # payment_intent.succeeded webhook; the caller passes a $db connected to the
    # tenant schema the enrollments live in. Enrollment items and the tenant are
    # snapshotted into metadata at create_payment time.
    method finalize_enrollment ($db) {
        my $items =
            ( ref $metadata eq 'HASH' && ref $metadata->{enrollment_items} eq 'ARRAY' )
            ? $metadata->{enrollment_items}
            : [];
        return unless @$items;

        require Registry::DAO::Enrollment;
        require Registry::DAO::Notification;

        for my $item (@$items) {
            my $session_id = $item->{session_id} or next;

            Registry::DAO::Enrollment->create_for_payment($db, {
                session_id       => $session_id,
                family_member_id => $item->{child_id},
                parent_id        => $user_id,
                status           => 'active',
                payment_id       => $id,
            });

            # Confirmation email is best-effort: a failure must not abort
            # enrollment of remaining items. Enrollment creation above is
            # the critical step; the email can be retried or re-sent later.
            try {
                Registry::DAO::Notification->ensure_enrollment_confirmation($db, {
                    user_id    => $user_id,
                    session_id => $session_id,
                    child_id   => $item->{child_id},
                });
            }
            catch ($e) {
                warn "finalize_enrollment: enrollment confirmation failed for session $session_id (payment $id): $e";
            }
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
                amount => _to_cents($refund_amount),
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
            amount        => _to_cents($amount),
            currency      => $currency,
            description   => $description,
            receipt_email => $receipt_email,
            _stripe_metadata_params($user_id, $self->id, $metadata),
        })->then(sub ($intent) {
            # Update payment record with Stripe intent ID
            $stripe_payment_intent_id = $intent->{id};
            $self->update($db, {
                stripe_payment_intent_id => $stripe_payment_intent_id
            });
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
            amount => _to_cents($refund_amount),
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