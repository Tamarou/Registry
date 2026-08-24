use 5.42.0;
use warnings;


use Object::Pad;
class Registry::DAO::Payment :isa(Registry::DAO::Object) {

use Registry::Service::Stripe;
use Registry::PriceOps::RevenueShare;
use Mojo::JSON qw(encode_json decode_json);

field $id :param :reader = undef;
field $user_id :param :reader = undef;
field $amount_cents :param :reader = 0;
field $currency :param :reader = 'USD';
field $status :param :reader = 'pending';
field $stripe_payment_intent_id :param :reader = undef;
field $stripe_payment_method_id :param :reader = undef;
field $metadata :param :reader = {};
field $completed_at :param :reader = undef;
field $error_message :param :reader = undef;

# The obligation, as typed columns rather than jsonb. Readers so callers and
# tests stop reaching into metadata for money -- that blob is where the debt
# used to live, and an operator could put a quoted string in it.
field $refund_owed_cents :param :reader = 0;
field $refunded_cents    :param :reader = 0;
field $refund_seq        :param :reader = 0;
field $refund_increments :param :reader = undef;
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
    sub _connect_params ($db, $metadata, $amount_cents) {
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
            application_fee_amount       => application_fee_cents($amount_cents, $fraction),
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

    # Request body for a PaymentIntent create call.
    #
    # Stripe's API is form-encoded; nested hashes must be flattened to bracket
    # notation (metadata[key]=value). Mojo's form generator would otherwise turn
    # a nested hashref into a bogus multipart upload and the metadata would
    # never reach Stripe. Metadata values must be strings, so refs (e.g.
    # enrollment_items) are snapshotted only in the DB metadata column, not sent
    # to Stripe.
    #
    # Shared by the sync and async wrappers so the Connect routing, application
    # fee, and idempotency key are derived in exactly one place.
    method _intent_params ($db, $args) {
        return {
            amount            => $amount_cents,
            currency          => $currency,
            description       => $args->{description} // 'Registry Program Enrollment',
            receipt_email     => $args->{receipt_email},
            _idempotency_key  => $self->_charge_idempotency_key,
            _stripe_metadata_params($user_id, $self->id, $metadata),
            _connect_params($db, $metadata, $amount_cents),
        };
    }

    # Stamp the created intent onto the payment row and hand back the pair the
    # checkout form needs.
    # save rather than update: the inherited update() carps and continues on a
    # database error, so a Stripe intent that exists but was never recorded
    # would pass silently and the parent would be charged against a row that
    # does not know its own intent id. Note this stays 'pending' -- recording an
    # intent is not completing a payment.
    # Every whole-row write to a payment takes the lock, re-reads under it, and
    # refuses a row whose money has already moved.
    #
    # save() writes six columns from the in-memory object. From a stale object
    # that is not a field update, it is a whole-row restore: the old status, a
    # nulled completed_at, a superseded intent id. The decline-retry path
    # produces exactly such an object -- it cancels the old intent over the
    # network, outside any transaction, and a webhook can capture the payment
    # while that round trip is in flight. The retry then walks the captured row
    # back to pending and hands the parent a live card form for money already
    # taken.
    method _guard_settled_write ($db, $what) {
        $self->_lock_and_refresh($db)
            or die "$what: payment $id no longer exists\n";
        return 0 if __CLASS__->_money_has_moved($status);
        return 1;
    }

    method _record_intent ($db, $intent) {
        return { client_secret => $intent->{client_secret},
                 payment_intent_id => $intent->{id} }
            unless $self->_guard_settled_write( $db, '_record_intent' );

        $stripe_payment_intent_id = $intent->{id};
        $self->save($db);

        return {
            client_secret => $intent->{client_secret},
            payment_intent_id => $intent->{id},
        };
    }

    # save for the same reason as _record_intent: a failure that the database
    # never learned about must not be swallowed on the way to the die below.
    method _record_intent_failure ($db, $error) {
        # A row whose money has moved is not failed by a later decline: the
        # webhook that captured it wins over an in-flight retry.
        unless ( $self->_guard_settled_write( $db, '_record_intent_failure' ) ) {
            die "Failed to create payment intent: $error";
        }

        $error_message = $error;
        $status = 'failed';
        $self->save($db);
        die "Failed to create payment intent: $error";
    }

    method create_payment_intent ($db, $args = {}) {
        my $intent;
        try {
            $intent = $self->stripe_client->create_payment_intent(
                $self->_intent_params($db, $args)
            );
        }
        catch ($e) {
            $self->_record_intent_failure($db, $e);
        }

        return $self->_record_intent($db, $intent);
    }
    
    # Has money already moved for this row?
    #
    # Before this leg the money path only ever held 'completed', so a
    # completed-only test was sufficient everywhere. The capacity gate added
    # refund_pending, and refunding adds refunded/partially_refunded -- three
    # states in which the charge has been made and, in two of them, given back.
    # Every place that used to ask "is this completed?" to mean "has this been
    # settled?" has to ask this instead, or a later delivery walks a refunded
    # row back to completed and settles it again.
    sub _money_has_moved ($class, $status) {
        return ( $status // '' )
            =~ /\A (?: completed | refunded | partially_refunded | refund_pending ) \z/x
            ? 1 : 0;
    }

    method _record_retrieval_failure ($db, $error) {
        # Re-read under the lock before writing a failure. This runs when Stripe
        # could not be reached, which says nothing about the row -- and another
        # settlement may have completed it while this one was waiting on the
        # network. Downgrading then leaves a live enrollment against a failed
        # payment. The success branch takes this lock; the failure branch was
        # reasoned out of it on the grounds that "nothing was applied", which is
        # true of Stripe and false of the database.
        $self->_lock_and_refresh($db);

        if ( __CLASS__->_money_has_moved($status) ) {
            return {
                success           => 0,
                already_completed => 1,
                error             => $error,
            };
        }

        $error_message = $error;
        $status = 'failed';
        $self->save($db);
        return { success => 0, error => $error };
    }

    method process_payment ($db, $payment_intent_id) {
        # Retrieve payment intent from Stripe
        my $intent;
        try {
            $intent = $self->stripe_client->retrieve_payment_intent($payment_intent_id);
        }
        catch ($e) {
            return $self->_record_retrieval_failure($db, $e);
        }

        return $self->_apply_intent($db, $intent, $payment_intent_id);
    }

    # Interpret a retrieved PaymentIntent against this payment row and move the
    # row's status accordingly. Shared by the sync and async wrappers: the
    # ownership and captured-amount guards are the security-critical part of the
    # money path and must not be able to drift apart between the two callers.
    # Take the row lock and re-read the status under it, before anything is
    # decided from that status. Both settlement paths reach here, and both
    # read-decide-write: without the lock two concurrent settlements can each
    # read 'pending', each conclude they should act, and each write.
    #
    # The lock is only a lock inside a transaction -- outside one Postgres
    # releases it as the statement ends. process_payment_async opens that
    # transaction immediately before calling this, and the webhook opens its own
    # around the whole settlement.
    #
    # Re-reading matters as much as locking: $status was loaded before the
    # Stripe round trip, so deciding on the in-memory copy would decide on a
    # value that another settlement may have moved while we waited on the
    # network.
    # Re-read every field save() will write back, not just the one being
    # decided on. save() is a whole-row write of six columns from the in-memory
    # object, so refreshing only $status leaves the other five at values loaded
    # before the Stripe round trip -- and writes those stale values over
    # whatever another settlement committed while this one waited on the
    # network. That erases a capacity debt (refund_owed_cents lives in
    # $metadata), restores a superseded intent id over a rotated one, and
    # resurrects a cleared error message.
    #
    # $amount_cents is refreshed too: it is what the intent's captured amount is
    # checked against, and a cart refreshed mid-flight must be compared against
    # its current price, not the one this object was built with.
    method _lock_and_refresh ($db) {
        my $locked = __CLASS__->find($db, { id => $id }, { for => 'update' })
            or return 0;

        $status                   = $locked->status;
        $amount_cents             = $locked->amount_cents;
        $metadata                 = $locked->metadata;
        $stripe_payment_intent_id = $locked->stripe_payment_intent_id;
        $stripe_payment_method_id = $locked->stripe_payment_method_id;
        $completed_at             = $locked->completed_at;
        $error_message            = $locked->error_message;

        return 1;
    }

    method _apply_intent ($db, $intent, $payment_intent_id) {
        $self->_lock_and_refresh($db);

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

        # A captured payment must not be demoted by a superseded intent. The
        # ownership check above cannot tell them apart: every intent ever minted
        # for this row is stamped with our payment_id (_stripe_metadata_params),
        # so the one cancelled after a declined first attempt still passes.
        # Letting it reach the else-branch flips a paid row to 'failed', which
        # sends the caller on to mint a replacement intent and offer a live card
        # form to a parent who has already paid.
        #
        # Reported as its own outcome rather than a failure: the payment is
        # fine, and the caller should carry on to completion, not show an error.
        # Widened from `completed` to every status in which money has moved.
        # A refunded row reaching the succeeded branch below is driven back to
        # completed, re-demoted by the capacity gate, and refunded a second time
        # -- with only Stripe's 24-hour key retention standing between that and
        # a genuine double refund. A refund_pending row is walked back before
        # its refund has even been issued.
        if ( __CLASS__->_money_has_moved($status) ) {
            return {
                success           => 0,
                already_completed => 1,
                error             => "Payment is already settled (status '$status')",
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
            if ( defined $intent->{amount} && $intent->{amount} != $amount_cents ) {
                return {
                    success => 0,
                    error   => 'Payment intent amount does not match payment record',
                };
            }

            $stripe_payment_method_id = $intent->{payment_method};
            $self->mark_completed($db, $stripe_payment_intent_id // $intent->{id});

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
    # Lock every session in the cart, in id order, before any capacity decision
    # is made about them.
    #
    # Sorted is the whole point. A multi-session cart takes one lock per item,
    # and iterating the cart in its own order means two carts holding the same
    # pair of sessions can each take one and wait for the other. Postgres
    # applies ORDER BY before locking -- LockRows sits above Sort in the plan --
    # so a single sorted statement takes them in a total order every cart
    # agrees on. Verified by execution: the unsorted form deadlocks two
    # concurrent carts, the sorted form does not.
    #
    # DISTINCT because a cart with two children in one session would otherwise
    # name it twice.
    method _lock_cart_sessions ($db, $items) {
        $db = $db->db if $db isa Registry::DAO;

        my %seen;
        my @session_ids =
            sort grep { !$seen{$_}++ }
            grep { defined && length }
            map  { $_->{session_id} } @$items;

        return unless @session_ids;

        $db->query(
            'SELECT id FROM sessions WHERE id = ANY(?) ORDER BY id FOR UPDATE',
            \@session_ids
        );
        return;
    }

    method finalize_enrollment ($db) {
        # Seating anyone against money that has gone back to the payer is a
        # delivery the parent no longer paid for. Returned, not "returned or
        # owed back" -- refund_pending is owed and is deliberately outside this
        # set; see _money_returned. The webhook's guard above
        # covers mark_completed only, so without this a redelivery onto a
        # refunded row re-adjudicates the whole cart and seats every unseated
        # item.
        #
        # NOT _money_has_moved: mark_completed runs immediately above this in
        # the same transaction, so on the normal path $status is already
        # 'completed' by the time we get here and that predicate would refuse
        # every first settlement. The question here is narrower -- has this
        # money gone back to the payer.
        return if __CLASS__->_money_returned($status);

        my $items =
            ( ref $metadata eq 'HASH' && ref $metadata->{enrollment_items} eq 'ARRAY' )
            ? $metadata->{enrollment_items}
            : [];
        return unless @$items;

        require Registry::DAO::Enrollment;
        require Registry::DAO::Notification;

        $self->_lock_cart_sessions($db, $items);

        my $owed_cents = 0;
        my @owed_children;

        # Count what this cart already holds BEFORE deciding anything, so the
        # arithmetic does not depend on the order items happen to sit in.
        # payment_fits_session excludes this payment's own rows, so a held seat
        # only counts through %granted -- and crediting it as the loop reaches
        # it means an unseated item earlier in the list is adjudicated against a
        # capacity that under-counts by every seat still ahead of it.
        #
        # The loop below re-reads each state rather than caching these. The
        # earlier justification here -- that a cart could hold the same
        # (session, child) twice -- was wrong: MultiChildSessionSelection keys
        # %selections by child id, so each child appears exactly once. The
        # re-read is kept because the loop writes enrollment rows as it goes and
        # a cached state would be stale against its own writes; it is not
        # load-bearing for duplicates, which cannot occur.
        my %granted;   # session_id => seats this cart holds in this session
        for my $item (@$items) {
            my $sid = $item->{session_id} or next;
            $granted{$sid}++
                if Registry::DAO::Enrollment->cart_seat_state(
                    $db, $id, $sid, $item->{child_id} ) eq 'seated';
        }

        for my $item (@$items) {
            my $session_id = $item->{session_id} or next;

            # What this cart already holds here decides whether we adjudicate.
            #
            # A seat in hand is left alone AND counted against this cart's own
            # capacity: payment_fits_session excludes this payment's rows, so
            # skipping without counting makes the cart invisible to itself and
            # it oversells the session on the next delivery. The two have to
            # move together -- fixing the vocabulary without the count just
            # changes which way it is wrong.
            my $held = Registry::DAO::Enrollment->cart_seat_state(
                $db, $id, $session_id, $item->{child_id} );

            next if $held eq 'seated';

            # cancelled, refunded, or anything else terminal belongs to whoever
            # put it there. Re-adjudicating it un-does an admin drop and re-owes
            # a share another system has already returned.
            next if $held eq 'closed';

            # An earlier delivery already demoted this child and owed their
            # share back. Re-adjudicating cannot promote them -- create_for_payment
            # conflicts on (session_id, student_id, payment_id) against the very
            # row that demotion wrote and does nothing -- but it would still
            # credit %granted for a seat that was never created and send a
            # confirmation email to a family whose child is on the waitlist.
            # The phantom grant then under-counts capacity for the next item in
            # this session, which is the defect the pre-pass above exists to
            # prevent, reintroduced one item at a time.
            next if $held eq 'waitlisted';

            # The seat was checked before the parent paid and is granted after.
            # In between is a Stripe round trip, so it is re-checked here, under
            # the lock taken above, before anything is written.
            unless (
                Registry::DAO::Enrollment->payment_fits_session(
                    $db, $self, $session_id, $granted{$session_id} // 0 )
            ) {
                # Only count a debt for a child this pass actually moved. A
                # redelivery re-runs the whole cart, and a child waitlisted by an
                # earlier delivery has already been owed for -- and possibly
                # already refunded.
                my $newly_demoted =
                    Registry::DAO::Enrollment->demote_to_waitlisted($db, {
                        session_id       => $session_id,
                        family_member_id => $item->{child_id},
                        parent_id        => $user_id,
                        payment_id       => $id,
                    });

                if ($newly_demoted) {
                    # Only this child's share: the cart may hold siblings whose
                    # seats are fine, and refunding the payment would take their
                    # money back too.
                    #
                    # The resolver refuses when no line item matches, which is
                    # right -- defaulting to the cart total refunds every
                    # sibling. But letting that refusal escape here rolls back a
                    # settlement Stripe has already captured, including the
                    # paying siblings' enrollments, and every retry reproduces it
                    # identically. A child can legitimately have no line item:
                    # calculate_enrollment_total skips any child whose plan
                    # returns no price, so they ride along in enrollment_items
                    # with nothing behind them. Flag it for a human and let the
                    # rest of the cart settle.
                    try {
                        $owed_cents += $self->refund_share_for($db, $item->{child_id}, $session_id);
                        push @owed_children, $item->{child_id};
                    }
                    catch ($e) {
                        # Persisted here, not left on $metadata for a later
                        # save(). The obligation writer stopped calling save()
                        # when the debt moved to typed columns, so an in-memory
                        # flag would never reach the row -- and a cart whose
                        # ONLY problem is an unpriced child would settle looking
                        # clean, with nothing for the runbook to find.
                        $self->flag_refund_manual_review(
                            $db, $item->{child_id}, $session_id );
                        warn "finalize_enrollment: unresolvable refund share for "
                           . "child $item->{child_id} in session $session_id "
                           . "(payment $id): $e";
                    }
                }
                next;
            }

            Registry::DAO::Enrollment->create_for_payment($db, {
                session_id       => $session_id,
                family_member_id => $item->{child_id},
                parent_id        => $user_id,
                status           => 'active',
                payment_id       => $id,
            });
            $granted{$session_id}++;

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

        # Record the debt inside the same transaction as the demotion that
        # created it, so the two cannot come apart. The refund itself happens
        # after the COMMIT -- a refund inside this transaction is not undone by
        # the ROLLBACK the rest of the leg depends on, and a redelivery would
        # then refund a second time.
        #
        # If the process dies between the COMMIT and the refund, this row is
        # what the operator finds: refund_pending with the amount attached. The
        # runbook clears it by hand; there is no automated reader until Leg 3.
        $self->record_capacity_obligation( $db, $owed_cents, \@owed_children );

        return $owed_cents;
    }

    # Persist what this pass decided, merged with anything still outstanding.
    #
    # ACCUMULATE, never assign. An earlier delivery can have left an unpaid
    # debt: the refund failed, or the process died between COMMIT and refund.
    # This pass computes only what it newly demoted -- demote_to_waitlisted
    # reports transitions, not state -- so assigning would drop the earlier
    # balance, and no later pass can re-derive it because those children are
    # already waitlisted. That is money kept for a seat never delivered.
    #
    # The status is set for ANY unresolved obligation, including one that is
    # only a manual-review flag. Leaving such a row 'completed' hides it from
    # the operator runbook and from Leg 3's ProcessRefunds, both of which scan
    # for refund_pending -- a family waitlisted, unrefunded, and invisible.
    # The obligation, one increment at a time.
    #
    # Every method here is a targeted UPDATE naming only the columns it changes,
    # never save(). save() is a whole-row write of six columns from the
    # in-memory object, so from a stale object it is a restore; and the
    # arithmetic below has to be atomic against a concurrent settlement anyway.
    # This is the shape the settlement spec's section 2.3 generalises.

    # Append a new debt increment. The DELTA is recorded, not the running total:
    # refunding the accumulated balance under a key that changes as the balance
    # grows is how one debt gets paid twice, which is exactly what happened when
    # the key was derived from the owed-children list.
    method record_capacity_obligation ($db, $new_cents, $new_children = []) {
        $db = $db->db if $db isa Registry::DAO;
        return unless $new_cents;

        # Positive, not merely non-zero. A negative delta SUBTRACTS from a real
        # debt, and a large one violates payments_refund_owed_cents_check inside
        # the settlement transaction -- rolling back a charge Stripe has already
        # captured, with no enrollments, on a redelivery loop that reproduces it
        # forever. Reachable today: PricingPlan's percentage_discount is
        # unbounded, so a plan configured above 100 yields a negative share.
        # Flagged rather than swallowed, because a nonsense share is exactly the
        # case a human has to look at.
        if ( $new_cents < 0 ) {
            warn "record_capacity_obligation: refusing negative share "
               . "$new_cents on payment $id\n";
            $self->flag_refund_manual_review( $db, $_, undef ) for @$new_children;
            $self->flag_refund_manual_review( $db, undef, undef )
                unless @$new_children;
            return;
        }

        # The increment records the CLAMPED delta, not what was asked for, so
        # the increments always sum to refund_owed_cents. Clamping only the
        # balance -- as an earlier version did -- lets the increments total more
        # than the cart, and since the increments are what actually reach
        # Stripe, that is a refund larger than the payment.
        #
        # Clamped rather than allowed to violate
        # payments_refund_owed_cents_check: this runs inside the settlement
        # transaction, so a CHECK violation would roll back a captured charge.
        # Over-accumulation is a bug, but it must not cost the family their
        # enrollment. The WHERE clause means no room produces no increment at
        # all rather than a zero-cent one.
        # Headroom is what the charge has left AFTER money already returned, not
        # just after money currently owed. Settling drives refund_owed_cents to
        # zero, so a clamp that ignored refunded_cents handed the whole cart
        # back as headroom on every discharge -- and the increments, which are
        # what actually reach Stripe, could then total more than the charge.
        # Measured at 11000 against a 9000 cart.
        my $row = $db->query( <<'SQL', $new_cents, $new_cents,
            UPDATE payments
               SET refund_seq        = refund_seq + 1,
                   refund_owed_cents = refund_owed_cents + LEAST(
                       ?::integer, amount_cents - refund_owed_cents - refunded_cents),
                   refund_increments = refund_increments || jsonb_build_object(
                       'seq',        refund_seq + 1,
                       'cents',      LEAST(
                           ?::integer, amount_cents - refund_owed_cents - refunded_cents),
                       'children',   ?::jsonb,
                       'settled_at', NULL ),
                   status = 'refund_pending'
             WHERE id = ?
               AND amount_cents > refund_owed_cents + refunded_cents
         RETURNING refund_owed_cents, refund_seq
SQL
            encode_json($new_children), $id )->hash;

        # No room left. The debt is real and cannot be recorded, which is
        # precisely the case a human has to look at.
        unless ($row) {
            # Same fallback the negative-share branch above has. Without it, a
            # debt refused for lack of headroom on a cart with no named children
            # left no balance, no increment, no flag and no warning -- and
            # record_capacity_obligation is public with $new_children defaulted
            # to [].
            warn "record_capacity_obligation: no headroom for $new_cents cents "
               . "on payment $id\n";
            $self->flag_refund_manual_review( $db, $_, undef ) for @$new_children;
            $self->flag_refund_manual_review( $db, undef, undef )
                unless @$new_children;
            return;
        }

        $status = 'refund_pending';
        return $row->{refund_seq};
    }

    # A share this code cannot compute, recorded for a human.
    #
    # Kept in metadata rather than given a column: it is a list of
    # (child, session) pairs nothing filters on, and unlike the debt it carries
    # no arithmetic an operator can corrupt. What it does share with the debt is
    # the status -- a row with an unresolvable share is refund_pending, so the
    # runbook's finding query sees it even when the computable balance is zero.
    method flag_refund_manual_review ($db, $child_id, $session_id) {
        $db = $db->db if $db isa Registry::DAO;

        # The flag is written unconditionally. It records that a human has to
        # look at something, which is true whatever the status says -- and the
        # case that most needs recording is a debt on a row that already reached
        # a terminal refund status, since that debt cannot be represented as an
        # obligation at all. An earlier version guarded the whole statement on
        # the status, so exactly that case wrote nothing anywhere.
        $db->query( <<'SQL', encode_json([ { child_id => $child_id, session_id => $session_id } ]), $id );
            UPDATE payments
               SET metadata = jsonb_set( COALESCE(metadata, '{}'::jsonb),
                       '{refund_manual_review}',
                       COALESCE(metadata->'refund_manual_review', '[]'::jsonb) || ?::jsonb )
             WHERE id = ?
SQL

        # The status move is separate, and still refuses to walk a terminal row
        # back to refund_pending.
        my $moved = $db->query( <<'SQL', $id )->rows;
            UPDATE payments SET status = 'refund_pending'
             WHERE id = ? AND status NOT IN ('refunded', 'partially_refunded')
SQL
        $status = 'refund_pending' if $moved;
        return;
    }

    # What still has to reach Stripe. Ordered by seq so a retry sends the oldest
    # debt first, and so the caller's behaviour does not depend on jsonb order.
    method unsettled_refund_increments ($db) {
        $db = $db->db if $db isa Registry::DAO;
        return $db->query( <<'SQL', $id )->hashes->to_array;
            SELECT (e->>'seq')::int AS seq, (e->>'cents')::int AS cents
              FROM payments p, jsonb_array_elements(p.refund_increments) e
             WHERE p.id = ? AND e->>'settled_at' IS NULL
             ORDER BY (e->>'seq')::int
SQL
    }

    # Names the increment it pays for. Stable forever for that increment, so a
    # retry of a failed attempt is deduplicated by Stripe, and distinct from
    # every other increment, so a genuinely new debt is never folded into one
    # already sent.
    method capacity_refund_key ($seq) { return "refund:capacity:$id:$seq" }

    # Discharge one increment: mark it settled, subtract exactly its amount, and
    # add exactly its amount to the cumulative total returned.
    #
    # Subtracting, not deleting. The old code deleted the whole obligation, so a
    # debt that grew during the Stripe round trip was erased along with the part
    # that was actually paid -- no row, no status, nothing for the runbook.
    #
    # Idempotent: the settled_at IS NULL guard means a second call moves no
    # money. Both callers can retry freely.
    method settle_refund_increment ($db, $seq, $refund = {}) {
        $db = $db->db if $db isa Registry::DAO;

        # The CTE is the guard. If no UNSETTLED increment carries this seq the
        # subquery is empty, the UPDATE's FROM joins against nothing, no row is
        # touched, and ->hash is undef -- so a settle that moved no money
        # reports so. An earlier form keyed on `WHERE p.id = ?`, which is always
        # true: it returned success for a seq it had never settled, made both
        # callers' "matched no row after Stripe paid" branch unreachable, and
        # still ran the status move.
        my $row = $db->query( <<'SQL', $id, $seq, $seq, $refund->{id}, $id )->hash;
            WITH due AS (
                -- SUM, not a bare select. The jsonb rewrite below marks EVERY
                -- element with this seq settled, so subtracting only one of
                -- them would leave a balance no increment can discharge. A
                -- duplicate seq is unreachable from lib/, but the runbook hands
                -- operators an append block.
                SELECT SUM((e->>'cents')::int) AS cents
                  FROM payments p, jsonb_array_elements(p.refund_increments) e
                 WHERE p.id = ?
                   AND (e->>'seq')::int = ?
                   AND e->>'settled_at' IS NULL
                HAVING COUNT(*) > 0
            )
            UPDATE payments p
               SET refund_increments = COALESCE( (
                     SELECT jsonb_agg(
                              CASE WHEN (e->>'seq')::int = ?
                                    AND e->>'settled_at' IS NULL
                                   THEN e || jsonb_build_object(
                                            'settled_at', to_jsonb(NOW()),
                                            'refund_id',  to_jsonb(?::text) )
                                   ELSE e END
                              ORDER BY (e->>'seq')::int )
                       FROM jsonb_array_elements(p.refund_increments) e ),
                     -- jsonb_agg over zero rows is SQL NULL against a NOT NULL
                     -- column.
                     '[]'::jsonb ),
                   -- Floored and capped. Bare arithmetic violates the CHECK
                   -- constraints on a row whose columns drifted -- a hand-edited
                   -- one, or a balance zeroed by an operator while an increment
                   -- was still due -- and that throw happens AFTER Stripe paid,
                   -- rolling the settlement back and leaving the increment
                   -- unsettled. The redelivery then re-sends it, deduplicated
                   -- only for the 24 hours Stripe keeps the key.
                   --
                   -- The NULL hazard that argued against GREATEST/LEAST applies
                   -- to a scalar subquery, not to this join: no match produces
                   -- no CTE row and no update at all, so due.cents is never
                   -- NULL here.
                   refund_owed_cents = GREATEST( 0, p.refund_owed_cents - due.cents ),
                   refunded_cents    = LEAST( p.amount_cents,
                                              p.refunded_cents + due.cents )
              FROM due
             WHERE p.id = ?
         RETURNING p.refund_owed_cents, p.refunded_cents, p.amount_cents
SQL
        return unless $row;

        # Status follows the money, once nothing is left owed. A part-refunded
        # cart says so rather than claiming a full refund -- the ledger
        # distinction the runbook and Leg 3 both read.
        return $row if $row->{refund_owed_cents};

        # An unresolved manual-review flag holds the row in refund_pending even
        # with nothing computable left owed. That flag means a share this code
        # could not work out -- refunding the children it COULD work out does
        # not discharge it, and the runbook finds these rows by
        # status = 'refund_pending'. Moving the status here would hide an
        # obligation nobody has decided about.
        #
        # The old code deleted the flag on discharge. Its stated reason was
        # mechanical: a leftover flag re-entered the obligation write and
        # stamped refund_pending back over a terminal status. That path is gone
        # -- record_capacity_obligation returns early on a zero increment -- so
        # what is left is the money question, and the answer to that is no.
        my $now = $row->{refunded_cents} >= $row->{amount_cents}
            ? 'refunded' : 'partially_refunded';
        # Assigned only if the row actually moved. The UPDATE is triple-guarded
        # -- an unresolved manual-review flag deliberately holds the row in
        # refund_pending -- and an unconditional assignment made the object
        # claim a status the row had refused. That object is reused across the
        # caller's loop, and refund_async gates on this in-memory $status.
        my $moved = $db->query( <<'SQL', $now, $id )->rows;
            UPDATE payments SET status = ?
             WHERE id = ? AND status = 'refund_pending'
               AND COALESCE(jsonb_array_length(metadata->'refund_manual_review'), 0) = 0
SQL
        $status = $now if $moved;
        return $row;
    }



    method add_line_item ($db, $args) {
        $db = $db->db if $db isa Registry::DAO;
        
        die "Description required" unless defined $args->{description};
        die "Amount required" unless defined $args->{amount_cents};

        my $item = {
            payment_id => $self->id,
            enrollment_id => $args->{enrollment_id},
            description => $args->{description},
            amount_cents => $args->{amount_cents},
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

    # The one way a payment reaches 'completed'.  Both settlement paths call it,
    # so a webhook-settled payment and a callback-settled one end up the same
    # shape -- before this, only the callback path stamped completed_at and the
    # webhook left it NULL on an otherwise identical row.
    #
    # Not a swap for the intent-recording writes: _record_intent stamps an id on
    # a still-pending row and _record_intent_failure marks a failure.  Neither
    # completes anything, and routing them through here would complete a payment
    # at intent-creation time and again on failure.
    method mark_completed ($db, $payment_intent_id) {
        $status                   = 'completed';
        $stripe_payment_intent_id = $payment_intent_id;
        $completed_at             = \'NOW()';
        $self->save($db);
        return $self;
    }

    # Replace the idempotency token with a fresh UUID and persist immediately.
    # Call this before retrying a declined intent so the retry is a genuinely
    # new Stripe charge rather than a duplicate of the failed one.
    method rotate_idempotency_token ($db) {
        # Rotating the token on a settled row would save() the stale object
        # over a captured payment. Nothing to rotate once the money moved.
        return unless $self->_guard_settled_write( $db, 'rotate_idempotency_token' );

        $db = $db->db if $db isa Registry::DAO;
        $metadata->{idempotency_token} = $db->query(
            'SELECT gen_random_uuid()::text AS uuid'
        )->hash->{uuid};
        $self->save($db);
    }

    # One child's share of a family cart.
    #
    # A payment is a cart, and refunding "the payment" because one child lost a
    # seat returns every sibling's money too. The line items carry
    # (child_id, session_id) in metadata -- calculate_enrollment_total writes
    # both on every row -- so a child's share is the sum of the items matching
    # that pair.
    #
    # Deliberately not payment_items.enrollment_id: line items are written
    # before the charge and enrollments only exist after settlement, so that
    # column cannot be populated at the natural write point.
    #
    # Refuses rather than defaulting. A silent fallback to the cart total is
    # precisely the mistake this exists to prevent, and it is the expensive
    # direction to be wrong in.
    method refund_share_for ($db, $child_id, $session_id) {
        $db = $db->db if $db isa Registry::DAO;

        # COUNT as well as SUM: no matching line item and a matching one worth
        # nothing are different answers, and only the first is an error.
        my $row = $db->query(
            q{SELECT COUNT(*) AS n, COALESCE(SUM(amount_cents), 0) AS cents
                FROM payment_items
               WHERE payment_id = ?
                 AND metadata->>'child_id'   = ?
                 AND metadata->>'session_id' = ?},
            $id, $child_id, $session_id
        )->hash;

        die "refund_share_for: no line item for child $child_id in session "
          . "$session_id on payment $id\n"
            unless $row->{n};

        return $row->{cents};
    }

    # Money has moved for exactly two statuses: a completed payment, and one the
    # capacity gate has marked refund_pending on its way to refunding it. The
    # gate writes that status inside its transaction and calls a refund after
    # the COMMIT, so a guard that only admits 'completed' means the refund it
    # just decided on never reaches Stripe.
    #
    # An allow-list rather than a widened deny-list: 'pending' and 'failed' rows
    # were never charged, and refunding one would send money that never arrived.
    # A third status classifier, and it is deliberately named rather than
    # inlined at its one call site so that the collapse in the settlement
    # spec's section 2.1 has something to grep for. It answers a question
    # neither of the other two asks: not "did money move" (_money_has_moved,
    # which includes completed) and not "may we refund" (_refundable_status,
    # which also includes completed), but "has this money gone back to the
    # payer" -- the set in which no further seat may be granted.
    #
    # refund_pending is deliberately NOT in it, and the honest reason is
    # conservatism rather than a demonstrated need. That money is owed, not yet
    # returned, so refusing to adjudicate is a stronger claim than the evidence
    # supports: no known production path leaves a cart item unadjudicated after
    # the first delivery, because every item with a session_id gets an
    # enrollment row on that pass -- seated on the fits branch, waitlisted on
    # the other -- and drops set status='cancelled' rather than deleting.
    #
    # An earlier version of this comment claimed the exclusion is what lets a
    # second delivery demote a second child and accumulate the balance. That is
    # false: the two tests covering it manufacture the state by hand, and the
    # refund retry does not depend on it either way, since the caller re-reads
    # refund_owed_cents straight off the row.
    #
    # It stays excluded because including it is the change that cannot be
    # undone safely: if such a state ever does arise, a gate that refuses to
    # adjudicate strands a paid-for child with no seat and no refund. Leaving
    # the row adjudicable is a no-op in every path we can find.
    sub _money_returned ($class, $status) {
        return ( $status // '' )
            =~ /\A (?: refunded | partially_refunded ) \z/x
            ? 1 : 0;
    }

    sub _refundable_status ($class, $status) {
        return ( $status // '' ) =~ /\A (?: completed | refund_pending ) \z/x ? 1 : 0;
    }

    # The bookkeeping the refund path applies once Stripe confirms.
    #
    # A synchronous refund() used to sit alongside refund_async with its own
    # copy of this: its own status transition, metadata writes and debt
    # clearing. The two drifted -- a fix applied to one silently left the other
    # behind -- and nothing in lib/ ever called the sync one, because every
    # money path runs under the daemon's event loop where _await refuses. It is
    # gone; this is the only copy.
    # Records the Stripe reference for the most recent refund, and nothing else.
    #
    # It used to own the discharge as well: set the status, and DELETE the whole
    # obligation. Both are wrong now and one always was. Deleting erased a debt
    # that grew during the round trip -- $refund_cents is captured before the
    # network call, so an increment recorded while it was in flight vanished
    # with the part actually paid, leaving no row and nothing for the runbook.
    # And the status cannot be decided from one refund's amount once refunds are
    # per-increment, because a 3000 increment of a 20000 cart is not a partial
    # refund of the cart, it is one instalment of the debt.
    #
    # settle_refund_increment owns both: it subtracts exactly the increment it
    # settles, adds exactly that to refunded_cents, and moves the status only
    # when nothing is left owed.
    method _apply_refund_result ($db, $refund, $refund_cents, $reason, $is_increment = 0) {
        $db = $db->db if $db isa Registry::DAO;

        # A targeted jsonb merge, not save(). save() would write six columns
        # from an object loaded before the Stripe round trip, over a row
        # settle_refund_increment may have moved in the meantime.
        #
        # The status move is conditional on THIS refund being an increment, not
        # on the row having any. Increments are never removed, so a
        # "has increments" test latched permanently on the first capacity
        # demotion -- and a later direct refund on the same payment then left
        # the bank while the ledger denied it.
        #
        # settle_refund_increment owns the status for an increment, because the
        # amount of any one instalment says nothing about whether the cart is
        # fully refunded. A direct refund has nothing else to move it, so it is
        # owned here -- and it ACCUMULATES refunded_cents rather than assigning,
        # so two successive direct refunds do not overwrite each other.
        # A direct refund is refused outright while a capacity debt is
        # outstanding. Writing a terminal status over a refund_pending row takes
        # it out of the runbook's queue AND out of _refundable_status, so the
        # outstanding increments can never be paid -- the money is stranded with
        # no operator able to find it.
        $db->query( <<'SQL', encode_json({
            UPDATE payments
               SET metadata = COALESCE(metadata, '{}'::jsonb) || ?::jsonb,
                   status = CASE
                       WHEN ?::boolean THEN status
                       -- A debt recorded between refund_async's check and this
                       -- write must not be buried under a terminal status. The
                       -- pre-flight read cannot be atomic with the Stripe call,
                       -- so the write re-checks.
                       WHEN refund_owed_cents > 0 THEN status
                       WHEN refunded_cents + ?::integer >= amount_cents THEN 'refunded'
                       ELSE 'partially_refunded' END,
                   refunded_cents = CASE
                       WHEN ?::boolean THEN refunded_cents
                       ELSE LEAST(amount_cents, refunded_cents + ?::integer) END
             WHERE id = ?
SQL
            refund_id           => $refund->{id},
            refund_amount_cents => $refund_cents,
            refund_reason       => $reason,
        }), $is_increment ? 1 : 0, $refund_cents,
            $is_increment ? 1 : 0, $refund_cents, $id );

        # Refresh the in-memory status for the direct path. refund_async gates
        # on this field, and leaving it stale let a second full refund through
        # on the same object -- a regression from main, where the status guard
        # caught it.
        $status = $db->query( 'SELECT status FROM payments WHERE id = ?', $id )
            ->hash->{status} unless $is_increment;
        return;
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
            my $price_cents = $pricing->calculate_price({
                child_count => 1,
                date => time(),
                %$child
            });

            if (defined $price_cents) {
                $total += $price_cents;

                push @$items, {
                    description => "$child->{first_name} $child->{last_name} - " . $session->name,
                    amount_cents => $price_cents,
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
    
    # Async payment methods. These are what the web request path uses: a
    # blocking Stripe call inside the running IOLoop can never settle, because
    # Mojo::Promise::wait is a no-op once its loop is already running.
    method create_payment_intent_async ($db, $args = {}) {
        return $self->stripe_client->create_payment_intent_async(
            $self->_intent_params($db, $args)
        )->then(
            sub ($intent) { $self->_record_intent($db, $intent) },
            sub ($error)  { $self->_record_intent_failure($db, $error) },
        );
    }
    
    # Two-argument then: the rejection handler must see only a failed retrieval.
    # A single trailing ->catch would also swallow anything _apply_intent threw
    # and mis-record it as a Stripe transport failure.
    #
    # $settle runs the caller's own settlement inside the same transaction as
    # _apply_intent's completed-write. Both are money writes on the same row and
    # splitting them across transactions leaves the window this exists to close:
    # a failure after the status write but before the enrollment strands a row
    # marked paid with nothing delivered. The transaction cannot open any
    # earlier -- retrieve_payment_intent_async is a network round trip, and
    # holding a payment row locked across it is exactly what the leg forbids.
    #
    # Called without $settle the method behaves as before, so callers that only
    # want the intent applied are unaffected.
    method process_payment_async ($db, $payment_intent_id, $settle = undef) {
        return $self->stripe_client->retrieve_payment_intent_async($payment_intent_id)
            ->then(
                sub ($intent) {
                    my $tx     = $db->begin;
                    my $result = $self->_apply_intent($db, $intent, $payment_intent_id);
                    my $out    = $settle ? $settle->($result) : $result;
                    $tx->commit;
                    return $out;
                },
                sub ($error)  {
                    # This branch needs the same transaction as the success one.
                    # Its own write is a single statement -- but when the row is
                    # already settled it returns already_completed, and
                    # _settle_callback treats that exactly like success, so the
                    # whole settlement runs here: capacity re-check, demotion,
                    # debt write. Unprotected, that oversells a session and
                    # leaves the demotion and its obligation able to come apart.
                    my $tx     = $db->begin;
                    my $result = $self->_record_retrieval_failure($db, $error);
                    my $out    = $settle ? $settle->($result) : $result;
                    $tx->commit;
                    return $out;
                },
            );
    }
    
    method refund_async ($db, $args = {}) {
        die "Cannot refund a payment with status '$status'"
            unless __CLASS__->_refundable_status($status);
        die "No Stripe payment intent ID" unless $stripe_payment_intent_id;

        my $refund_cents = $args->{amount_cents} // $amount_cents;
        my $reason = $args->{reason} // 'requested_by_customer';

        # Refused BEFORE the money moves. An earlier version of this guard sat
        # in _apply_refund_result, which runs inside create_refund_async's
        # ->then -- so it fired after Stripe had already paid, recorded nothing,
        # and the ->catch below rewrote it as "Refund failed". That tells the
        # caller no money moved when it did, and the direct path sends no
        # idempotency key, so the retry it invites is a second real refund.
        #
        # Writing a terminal status over a refund_pending row would take it out
        # of both the runbook's queue and _refundable_status, stranding the
        # outstanding increments where nobody can find them.
        unless ( $args->{idempotency_key} ) {
            my $owed = $db->query(
                'SELECT refund_owed_cents FROM payments WHERE id = ?', $id
            )->hash->{refund_owed_cents} // 0;
            die "Cannot issue a direct refund while $owed cents of capacity "
              . "debt is outstanding on payment $id\n" if $owed;
        }

        return $self->stripe_client->create_refund_async({
            payment_intent => $stripe_payment_intent_id,
            amount         => $refund_cents,
            reason         => $reason,
            $self->_refund_connect_params($db),
            $args->{idempotency_key}
                ? ( _idempotency_key => $args->{idempotency_key} ) : (),
        })->then(sub ($refund) {
            # An increment always travels under a per-increment idempotency key;
            # a direct refund has none. That is what distinguishes the two here.
            $self->_apply_refund_result( $db, $refund, $refund_cents, $reason,
                $args->{idempotency_key} ? 1 : 0 );
            return $refund;
        })->catch(sub ($error) {
            die "Refund failed: $error";
        });
    }
}

1;