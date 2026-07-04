use 5.42.0;
use warnings;


use Object::Pad;
class Registry::DAO::Payment :isa(Registry::DAO::Object) {

use Registry::Service::Stripe;
use Registry::PriceOps::RevenueShare;
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
    
    sub table { 'payments' }

    # Convert a dollar amount to integer cents for Stripe API calls.
    sub _to_cents ($dollars) { int($dollars * 100) }

    # Platform revenue share, collected at charge time as a Stripe application
    # fee on the destination charge. The fraction is resolved from the tenant's
    # plan by the caller. Integer cents, rounded half-up.
    sub application_fee_cents ($amount_cents, $fraction) {
        return int($amount_cents * $fraction + 0.5);
    }

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

    # Derive Stripe Connect destination-charge params from a tenant slug and
    # amount. Tenant payments are destination charges: tuition settles into the
    # tenant's connected account, the platform keeps the application fee, and
    # on_behalf_of makes the tenant the settlement merchant (bearer of Stripe's
    # processing fee). Derived from the payment's own metadata so every intent
    # for this payment -- including retries -- routes the same way.
    # Platform/registry payments (no tenant_slug) are unchanged. The Task 5 gate
    # guarantees readiness before any tenant intent is created, so routing on
    # account presence (not re-checking readiness booleans) keeps this method
    # total. tenants has no jsonb columns; plain ->hash is sufficient.
    sub _connect_params ($db, $metadata, $amount) {
        $db = $db->db if $db isa Registry::DAO;
        my $meta = ref $metadata eq 'HASH' ? $metadata : {};
        my $slug = $meta->{tenant_slug};
        return unless $slug && $slug ne 'registry';

        my $row = $db->query(
            'SELECT stripe_connect_account_id FROM registry.tenants WHERE slug = ?',
            $slug
        )->hash;
        return () unless $row;
        my $acct = $row->{stripe_connect_account_id};
        return () unless $acct;

        # Resolve the revenue-share fraction from the tenant's linked plan
        # (Free 0% when the tenant has no plan link). $db is already a Mojo::Pg
        # handle here (coerced at the top of this sub).
        my $fraction = Registry::PriceOps::RevenueShare::revenue_share_fraction_for_tenant($db, $slug);

        return (
            'transfer_data[destination]' => $acct,
            on_behalf_of                 => $acct,
            application_fee_amount       => application_fee_cents(_to_cents($amount), $fraction),
        );
    }

    # Connect refunds: for a destination charge the tenant received the tuition, so
    # the transfer must be reversed; whether the platform also returns its
    # application fee is governed by the tenant's plan. Registry/platform payments
    # (no tenant_slug, or tenant_slug eq 'registry') are unchanged -- neither
    # parameter is sent and Stripe defaults apply.
    #
    # Stripe's form-encoded API (Stripe.pm posts `form => $data`) requires string
    # booleans ('true'/'false'). Sending numeric 1/0 yields an "Invalid boolean"
    # API error on every refund, so these values must always be strings.
    method _refund_connect_params ($db) {
        my $slug = ref $metadata eq 'HASH' ? $metadata->{tenant_slug} : undef;
        return () unless $slug && $slug ne 'registry';
        $db = $db->db if $db isa Registry::DAO;
        my $refund_fee =
            Registry::PriceOps::RevenueShare::refund_application_fee_for_tenant($db, $slug);
        return (
            reverse_transfer       => 'true',
            refund_application_fee => $refund_fee ? 'true' : 'false',
        );
    }

    sub create ($class, $db, $data) {
        my $raw_db = ($db isa Registry::DAO) ? $db->db : $db;

        # Ensure metadata is always a hashref with a stable idempotency token.
        # Token is set BEFORE the -json wrapping so it survives the ADJUST
        # decode round-trip on reload (Payment->find). UUID comes from the DB's
        # gen_random_uuid() to stay consistent with the schema idiom.
        $data->{metadata} = {} unless ref $data->{metadata} eq 'HASH';
        $data->{metadata}{idempotency_token} //= $raw_db->query(
            'SELECT gen_random_uuid()::text AS uuid'
        )->hash->{uuid};
        $data->{metadata} = { -json => $data->{metadata} };

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
    
    # The Stripe idempotency key for creating this payment's intent. Fails
    # loudly if the token is missing: a payment without one would send the
    # same bare "pi-create:" key as every other tokenless payment, and Stripe
    # would silently replay another payment's intent. Payment->create always
    # seeds the token, so this only fires for rows built outside it.
    method _charge_idempotency_key {
        die "Payment $id has no idempotency_token in metadata - "
          . "was it created outside Payment->create?"
            unless ref $metadata eq 'HASH' && defined $metadata->{idempotency_token};
        return 'pi-create:' . $metadata->{idempotency_token};
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
                amount            => _to_cents($amount),
                currency          => $currency,
                description       => $description,
                receipt_email     => $receipt_email,
                _idempotency_key  => $self->_charge_idempotency_key,
                _stripe_metadata_params($user_id, $self->id, $metadata),
                _connect_params($db, $metadata, $amount),
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

        # The posted intent id is client-controlled: only honor an intent that
        # belongs to THIS payment row -- either the id stored at creation time
        # or an intent stamped with our payment_id in its Stripe metadata.
        # Without this check, any succeeded intent id from anywhere on the
        # platform could complete an unrelated (and more expensive) enrollment.
        # Do not mutate status on mismatch: a forged id must not be able to
        # flip a payment to failed either.
        my $intent_id = $intent->{id} // $payment_intent_id;
        my $owned =
            ( defined $stripe_payment_intent_id && $intent_id eq $stripe_payment_intent_id )
            || ( ( $intent->{metadata}{payment_id} // '' ) eq $id );
        unless ($owned) {
            return {
                success => 0,
                error   => 'Payment intent does not belong to this payment',
            };
        }

        # Update payment status based on intent status
        if ($intent->{status} eq 'succeeded') {
            # The captured amount must match this row before completing: a
            # stale intent from before a cart refresh must not settle the
            # refreshed (differently-priced) cart. Intents without an amount
            # (internal fixtures) pass; real Stripe intents always carry one.
            # No status mutation on mismatch -- this is a refusal, not a
            # payment failure.
            if ( defined $intent->{amount} && $intent->{amount} != _to_cents($amount) ) {
                return {
                    success => 0,
                    error   => 'Payment intent amount does not match payment record',
                };
            }

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

            # Surface the raw intent status: the caller must distinguish a true
            # decline (requires_payment_method) from a customer mid-3DS
            # (requires_action) before deciding to mint a replacement intent.
            return {
                success       => 0,
                error         => $error_message,
                intent_status => $intent->{status},
            };
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
        
        $db->insert('payment_items', $item);
    }
    
    method line_items ($db) {
        $db = $db->db if $db isa Registry::DAO;
        my $items = $db->select('payment_items', '*', { payment_id => $self->id })->hashes;
        
        # Decode metadata for each item
        for my $item (@$items) {
            $item->{metadata} = decode_json($item->{metadata}) if $item->{metadata};
        }
        
        return $items;
    }
    
    # Persist the current in-memory field values back to the database row.
    # Called by state-mutation methods (refund, process_payment) after they
    # update fields like $status, $metadata, $completed_at, and $error_message.
    #
    # Intentionally bypasses the inherited Registry::DAO::Object::update(), which
    # silently carps and continues on database errors. Refund and payment state
    # must fail loudly: a Stripe refund that succeeds but whose DB record was not
    # updated would leave money in an inconsistent state.
    method save ($db) {
        $db = $db->db if $db isa Registry::DAO;
        $db->update($self->table, {
            status                   => $status,
            stripe_payment_intent_id => $stripe_payment_intent_id,
            stripe_payment_method_id => $stripe_payment_method_id,
            metadata                 => { -json => ($metadata // {}) },
            completed_at             => $completed_at,
            error_message            => $error_message,
        }, { id => $id });
    }

    # Replace the idempotency token with a fresh UUID and persist immediately.
    # Call this before retrying a declined intent so the retry is a genuinely
    # new Stripe charge rather than a duplicate of the failed one.
    method rotate_idempotency_token ($db) {
        $db = $db->db if $db isa Registry::DAO;
        $metadata->{idempotency_token} = $db->query(
            'SELECT gen_random_uuid()::text AS uuid'
        )->hash->{uuid};
        $self->save($db);
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
                amount         => _to_cents($refund_amount),
                reason         => $reason,
                $self->_refund_connect_params($db),
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
            'payments',
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
            amount            => _to_cents($amount),
            currency          => $currency,
            description       => $description,
            receipt_email     => $receipt_email,
            _idempotency_key  => $self->_charge_idempotency_key,
            _stripe_metadata_params($user_id, $self->id, $metadata),
            _connect_params($db, $metadata, $amount),
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
                # Same amount guard as the sync path: a stale intent must not
                # settle a refreshed, differently-priced cart. Refusal, not a
                # payment failure -- no status mutation.
                if (   $intent->{status} eq 'succeeded'
                    && defined $intent->{amount}
                    && $intent->{amount} != _to_cents($amount) )
                {
                    return {
                        success => 0,
                        error   => 'Payment intent amount does not match payment record',
                    };
                }

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
            amount         => _to_cents($refund_amount),
            reason         => $reason,
            $self->_refund_connect_params($db),
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