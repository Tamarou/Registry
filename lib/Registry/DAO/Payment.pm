use 5.42.0;
use warnings;


use Object::Pad;
class Registry::DAO::Payment :isa(Registry::DAO::Object) {

use Registry::Service::Stripe;
use Registry::PriceOps::RevenueShare;
use Mojo::JSON qw(encode_json decode_json);
use Mojo::Promise ();
use experimental 'keyword_any';

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

# What the platform took on this charge, and the plan version it took it under.
# NULL on both means NOT RECORDED -- every charge made before these columns
# existed, and any charge with no destination account (a registry/platform
# payment has no application fee at all). Zero would claim the platform took
# nothing, which is a different and sometimes false statement.
field $platform_fee_cents        :param :reader = undef;
field $platform_pricing_plan_id  :param :reader = undef;
field $created_at :param :reader = undef;
field $updated_at :param :reader = undef;

# An instalment of a set, or NULL throughout for an ordinary single charge --
# which is what every row was before #425. The obligation is a row from the
# moment of enrolment, so what a family still owes is a query here rather than a
# call to Stripe per family.
field $instalment_seq     :param :reader = undef;
field $instalment_count   :param :reader = undef;
field $due_date           :param :reader = undef;
field $stripe_schedule_id :param :reader = undef;

# True when this row is one of several. Asked rather than derived at each call
# site, so nothing has to remember that the pair is all-or-nothing.
method is_instalment { return defined $instalment_seq ? 1 : 0 }

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

    # --- Instalments -------------------------------------------------------
    #
    # A plan declares its instalment offer (PricingPlan::payment_schedule) and
    # resolves it to amounts and due dates (instalment_schedule). These two turn
    # that list into what Stripe needs. Deliberately pure functions: the shape
    # that decides where a family's money lands should be assertable without a
    # database or a network.

    # Group consecutive equal instalments into subscription-schedule phases.
    #
    # Stripe bills a phase for `iterations` periods at one `unit_amount`, so
    # three equal charges are one phase of three -- not three phases of one,
    # which would create three price objects for the same money.
    #
    # Unequal amounts are the normal case rather than the exception: $100 in
    # three is 33.33 / 33.33 / 33.34, and the odd cent has to be on one of them.
    # That is why this groups instead of assuming a single phase.
    sub instalment_phases ( $instalments, $currency, $description ) {
        my @phases;
        for my $part (@$instalments) {
            if ( @phases && $phases[-1]{unit_amount} == $part->{amount_cents} ) {
                $phases[-1]{iterations}++;
                next;
            }
            push @phases, {
                unit_amount => $part->{amount_cents},
                iterations  => 1,
                currency    => $currency,
                description => $description,
            };
        }
        return \@phases;
    }

    # The subscription-schedule request for the instalments still to come.
    #
    # Instalment one is taken on-session at checkout, where the parent is
    # present to satisfy a card challenge and the card is saved; this covers
    # what is left, charged automatically against that card. So `start_date` is
    # the second instalment's due date, not now.
    sub instalment_schedule_params ( $args ) {
        my $instalments = $args->{instalments} // [];
        my $currency    = lc( $args->{currency} // 'usd' );
        my $product     = $args->{product};

        my $phases = instalment_phases(
            $instalments, $currency, $args->{description} // 'Enrollment' );

        my %params = (
            customer   => $args->{customer},
            start_date => _epoch_for_date( $instalments->[0]{due_date} ),

            # It ends. An instalment plan is a fixed number of charges, and a
            # schedule that renewed would bill a family for a camp that finished
            # in August, every August.
            end_behavior => 'cancel',

            'default_settings[collection_method]'     => 'charge_automatically',
            'default_settings[default_payment_method]' => $args->{payment_method},

            # Destination charges, as the one-off path does in _connect_params:
            # the tenant is the merchant of record and our share is the
            # application fee. Without these every instalment would settle into
            # the PLATFORM's balance and the tenant would be paid nothing.
            'default_settings[transfer_data][destination]' => $args->{connect_account},
        );

        # Omitted rather than sent as zero. A tenant on the Free plan owes no
        # revenue share, and an explicit 0 is a value Stripe has no reason to
        # accept on a schedule that takes no fee.
        $params{'default_settings[application_fee_percent]'} = $args->{revenue_share_pct}
            if $args->{revenue_share_pct};

        for my $i ( 0 .. $#$phases ) {
            my $p = $phases->[$i];
            $params{"phases[$i][iterations]"} = $p->{iterations};
            $params{"phases[$i][items][0][price_data][currency]"}    = $p->{currency};
            $params{"phases[$i][items][0][price_data][unit_amount]"} = $p->{unit_amount};
            # A product id, not product_data. Stripe refuses inline product
            # data inside a schedule phase's price_data -- "Received unknown
            # parameter: product_data. Did you mean product?" -- so the caller
            # creates the product and passes its id.
            $params{"phases[$i][items][0][price_data][product]"} = $product;
            $params{"phases[$i][items][0][price_data][recurring][interval]"} = 'month';
        }

        return \%params;
    }

    # YYYY-MM-DD to an epoch second, which is what Stripe takes. Noon UTC rather
    # than midnight, so a timezone offset cannot move a due date onto the
    # previous day and charge a family a month early.
    sub _epoch_for_date ( $date ) {
        return time() unless defined $date && $date =~ /^(\d{4})-(\d{2})-(\d{2})$/;
        require Time::Local;
        return Time::Local::timegm_posix( 0, 0, 12, $3, $2 - 1, $1 - 1900 );
    }

    # Create the Stripe schedule for the instalments after the first, and record
    # each of them as a payments row.
    #
    # Called from a job rather than from the webhook that completes instalment
    # one, for two reasons. The card only exists once that charge has succeeded,
    # so this cannot happen at checkout; and a blocking Stripe call inside a
    # webhook's transaction is the shape of #284 -- the work belongs after the
    # COMMIT, where a failure can be retried without holding a lock.
    #
    # Idempotent by the schedule id: a retried job finds one already recorded and
    # returns it rather than creating a second schedule that would double-bill
    # the family.
    method schedule_remaining_instalments ($db) {
        my $raw = ($db isa Registry::DAO) ? $db->db : $db;

        return $stripe_schedule_id if $stripe_schedule_id;
        return undef unless $self->is_instalment && $instalment_seq == 1;

        my $meta        = $metadata // {};
        my $instalments = $meta->{instalment_plan} or return undef;
        my @remaining   = @{$instalments}[ 1 .. $#$instalments ];
        return undef unless @remaining;

        my $slug = $meta->{tenant_slug}
            or die "cannot schedule instalments without a tenant slug\n";

        # Where the money goes, and what our share of it is -- read at scheduling
        # time from the tenant's linked plan, the same authority the one-off
        # charge path reads in _connect_params.
        my $acct = $raw->query(
            'SELECT stripe_connect_account_id FROM registry.tenants WHERE slug = ?',
            $slug )->hash->{stripe_connect_account_id}
            or die "tenant '$slug' has no Connect account to pay instalments into\n";

        my $pct = Registry::PriceOps::RevenueShare::revenue_share_fraction_for_tenant(
            $raw, $slug ) * 100;

        my $client = $self->stripe_client;

        # The customer the first charge was made against, and the card it saved.
        my $intent = $client->retrieve_payment_intent($stripe_payment_intent_id);
        my $customer = $intent->{customer}
            or die "instalment 1 of payment $id has no customer to bill\n";
        my $card = $intent->{payment_method}
            or die "instalment 1 of payment $id saved no card\n";

        my $description = $meta->{instalment_description} // 'Program Enrollment';
        my $product = $client->create_product({
            name                  => $description,
            'metadata[payment_id]' => $id,
        });

        my $schedule = $client->create_subscription_schedule(
            instalment_schedule_params( {
                customer          => $customer,
                payment_method    => $card,
                connect_account   => $acct,
                revenue_share_pct => $pct,
                currency          => lc $currency,
                description       => $description,
                product           => $product->{id},
                instalments       => \@remaining,
            } ) );

        # Recorded in one transaction with the rows it bills, so a crash between
        # them cannot leave a schedule at Stripe that Registry has no record of.
        my $txn = $raw->begin;

        $raw->update( 'payments', { stripe_schedule_id => $schedule->{id} },
            { id => $id } );

        my $seq = 1;
        for my $part (@remaining) {
            $seq++;
            $raw->insert( 'payments', {
                user_id            => $user_id,
                amount_cents       => $part->{amount_cents},
                currency           => $currency,
                status             => 'pending',
                instalment_seq     => $seq,
                instalment_count   => $instalment_count,
                due_date           => $part->{due_date},
                stripe_schedule_id => $schedule->{id},
                metadata           => { -json => {
                    instalment_of => $id,
                    tenant_slug   => $slug,
                    description   => $description,
                } },
            } );
        }

        $txn->commit;
        $stripe_schedule_id = $schedule->{id};
        return $schedule->{id};
    }

    # The instalments of this set that are still owed, earliest first. Morgan's
    # outstanding balance, and the row an arriving invoice belongs to.
    sub owed_instalments ( $class, $db, $schedule_id ) {
        my $raw = ($db isa Registry::DAO) ? $db->db : $db;
        return $raw->query( q{
            SELECT * FROM payments
             WHERE stripe_schedule_id = ?
               AND status IN ('pending', 'failed')
             ORDER BY instalment_seq
        }, $schedule_id )->expand->hashes
          ->map( sub { $class->new( %$_ ) } )->to_array;
    }

    # What families still owe on instalment plans, for Morgan's dashboard.
    #
    # A query over her own schema rather than a call to Stripe per family, which
    # is why every instalment is a row from the moment of enrolment rather than
    # something derived when asked.
    #
    # Failures first, then by due date: a card that was declined needs her
    # attention now, where an instalment due in August does not.
    sub outstanding_instalments ( $class, $db, %opt ) {
        my $raw = ($db isa Registry::DAO) ? $db->db : $db;
        my $limit = $opt{limit} // 50;

        return $raw->query( q{
            SELECT p.id, p.amount_cents, p.currency, p.status, p.due_date,
                   p.instalment_seq, p.instalment_count, p.error_message,
                   p.user_id, up.name AS payer_name, up.email AS payer_email
              FROM payments p
              LEFT JOIN user_profiles up ON up.user_id = p.user_id
             WHERE p.instalment_seq IS NOT NULL
               AND p.status IN ('pending', 'failed')
             ORDER BY (p.status = 'failed') DESC, p.due_date, p.instalment_seq
             LIMIT ?
        }, $limit )->hashes->to_array;
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
    
    # The env-reading and the live-key guard live on the service now, so the
    # Connect-onboarding controller enforces the same rule rather than growing a
    # second copy of it. This keeps the per-payment cache.
    method stripe_client {
        return $_stripe_client if $_stripe_client;

        # Handle SSL requirement gracefully in test environments
        eval { $_stripe_client = Registry::Service::Stripe->from_env };

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
    # Pure: builds the params and makes no call. The customer is passed IN
    # rather than fetched here, which is the whole point -- this runs
    # synchronously inside create_payment_intent_async, before any promise
    # exists, so a network call from here happens in the live IOLoop where a
    # blocking ->wait can never settle (#284).
    method _intent_params ($db, $args, $customer_id = undef) {
        die "an instalment intent needs a Stripe customer; resolve one before "
          . "building the params\n"
          if $self->is_instalment && !$customer_id;

        return {
            amount            => $amount_cents,
            currency          => $currency,
            description       => $args->{description} // 'Registry Program Enrollment',
            receipt_email     => $args->{receipt_email},
            _idempotency_key  => $self->_charge_idempotency_key,

            # Instalment one is the only charge a parent is present for. The
            # card has to be kept, or instalments two and three have nothing to
            # bill -- and asked for HERE, on-session, because that is where the
            # cardholder can satisfy a challenge. A schedule created later
            # against a card that was never saved off-session fails on its first
            # invoice, weeks after anyone is watching.
            ( $self->is_instalment
                ? ( setup_future_usage => 'off_session',
                    customer           => $customer_id )
                : () ),

            _stripe_metadata_params($user_id, $self->id, $metadata),
            _connect_params($db, $metadata, $amount_cents),
        };
    }

    # A Stripe customer for this payer, created on first need and remembered on
    # the payment's metadata. An instalment plan needs one: a saved card belongs
    # to a customer, and a bare PaymentIntent has nowhere to keep it.
    method _stripe_customer_for ($db) {
        my $raw = ($db isa Registry::DAO) ? $db->db : $db;

        return $metadata->{stripe_customer_id} if $metadata->{stripe_customer_id};

        my $customer = $self->stripe_client->create_customer(
            $self->_customer_params($raw) );

        return $self->_remember_customer( $raw, $customer->{id} );
    }

    # The async sibling, for the request path. Same early return, same recording
    # step; only the Stripe call differs, and it has to be the one that defers.
    method _stripe_customer_async ($db) {
        my $raw = ($db isa Registry::DAO) ? $db->db : $db;

        return Mojo::Promise->resolve( $metadata->{stripe_customer_id} )
          if $metadata->{stripe_customer_id};

        return $self->stripe_client
          ->create_customer_async( $self->_customer_params($raw) )
          ->then( sub ($customer) {
              $self->_remember_customer( $raw, $customer->{id} );
          } );
    }

    method _customer_params ($raw) {
        require Registry::DAO::User;
        my $user = Registry::DAO::User->find( $raw, { id => $user_id } );

        return {
            ( $user && $user->email ? ( email => $user->email ) : () ),
            ( $user && $user->name  ? ( name  => $user->name )  : () ),
            'metadata[registry_user_id]' => $user_id // '',
        };
    }

    # Recorded before the intent is created, so a retry reuses this customer
    # rather than leaving a trail of them with one saved card each.
    method _remember_customer ($raw, $customer_id) {
        $raw->query( q{
            UPDATE payments
               SET metadata = COALESCE(metadata, '{}'::jsonb)
                              || jsonb_build_object('stripe_customer_id', ?::text)
             WHERE id = ?
        }, $customer_id, $id );
        $metadata->{stripe_customer_id} = $customer_id;

        return $customer_id;
    }


    method _record_intent ($db, $intent) {
        # The refusal and the write are one statement now: no lock, no refresh,
        # and no window between deciding and doing.
        $self->_record_intent_id( $db, $intent->{id} );

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
        $self->_record_intent_failure_write( $db, $error );
        die "Failed to create payment intent: $error";
    }

    method create_payment_intent ($db, $args = {}) {
        my $intent;
        try {
            # Blocking resolver here on purpose: this wrapper only runs where
            # no loop is running. The async path above uses the deferring one.
            my $customer_id =
              $self->is_instalment ? $self->_stripe_customer_for($db) : undef;
            $intent = $self->stripe_client->create_payment_intent(
                $self->_intent_params( $db, $args, $customer_id )
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
    # The statuses in which money has moved, as a list the SQL can bind.
    # _money_has_moved is the same set as a predicate; this is the same set as
    # data. Two conditional writes were carrying it as a hardcoded SQL literal,
    # which is a fifth and sixth encoding of "settled" in a file whose whole
    # point is that there were already too many.
    sub _settled_statuses ($class) {
        return [qw( completed refunded partially_refunded refund_pending )];
    }

    sub _money_has_moved ($class, $status) {
        my $s = $status // '';
        return ( any { $_ eq $s } @{ $class->_settled_statuses } ) ? 1 : 0;
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

        $self->_record_intent_failure_write( $db, $error );
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
        # Still refreshed, for the READ decisions below -- the ownership check
        # and the already-settled report both need current data to answer
        # correctly. The WRITES no longer depend on it: each carries its own
        # legality, so a decision made on stale data is refused by the statement
        # rather than acted on. _guard_settled_write is gone with them.
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

            # Branch on the write, not past it. Reporting success for a write
            # the database refused is how a captured charge ends up recorded as
            # something else while the caller carries on enrolling children.
            unless ( $self->mark_completed( $db,
                        $stripe_payment_intent_id // $intent->{id},
                        $intent->{payment_method} ) ) {
                return {
                    success => 0,
                    error   => "Payment could not be completed from status '$status'",
                };
            }

            # Record what the platform actually took, from what Stripe
            # reported -- never by recomputing the rate.
            #
            # This is the only moment the truth is available: _connect_params
            # computes the fee on the way out and keeps nothing, and afterwards
            # only Stripe knows. A figure derived later from the tenant's
            # current rate disagrees with the charge on every rate change
            # (#277), on every refund that returns the fee, and wherever
            # Stripe's rounding differs from ours -- so a revenue screen built
            # on derivation reports money that was never taken.
            $self->_record_platform_fee( $db, $intent );

            return { success => 1, payment => $self };
        } elsif ($intent->{status} eq 'processing') {
            $self->_record_processing($db);

            return { success => 0, processing => 1 };
        } else {
            $self->_record_intent_failure_write( $db,
                $intent->{last_payment_error}->{message} // 'Payment failed' );

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
    
    # Write down the application fee and the plan version it was charged under.
    #
    # Best effort: a failure here must not undo a captured charge. The payment is
    # settled and the enrolment is the point; an unrecorded fee leaves a NULL,
    # which the revenue view reports as a gap rather than silently summing as
    # zero.
    #
    # The plan is read now rather than at intent creation, which leaves a window
    # of seconds in which an admin could move the tenant between plan versions
    # and have this charge attributed to the newer one. Accepted deliberately:
    # moving a tenant is a deliberate act (#277), the window is one Stripe round
    # trip, and the alternative is threading the id through the params builder
    # and the webhook's run-less path for a case nobody has hit.
    method _record_platform_fee ( $db, $intent ) {
        $db = $db->db if $db isa Registry::DAO;

        my $fee = $intent->{application_fee_amount};
        return unless defined $fee && !ref $fee;

        my $slug = ( ref $metadata eq 'HASH' ? $metadata->{tenant_slug} : undef );

        my $plan_id;
        if ( defined $slug && !ref $slug && length $slug ) {
            my $row = $db->query(
                'SELECT platform_pricing_plan_id FROM registry.tenants WHERE slug = ?',
                $slug )->hash;
            $plan_id = $row && $row->{platform_pricing_plan_id};
        }

        eval {
            $db->update( 'payments',
                { platform_fee_cents       => $fee,
                  platform_pricing_plan_id => $plan_id },
                { id => $id } );
            $platform_fee_cents       = $fee;
            $platform_pricing_plan_id = $plan_id;
            1;
        } or do {
            my $err = $@ || 'unknown error';
            $err =~ s/\s+/ /g;
            warn "could not record platform fee for payment $id: $err\n";
        };

        return;
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

        # This statement locks `sessions`, but what it is really protecting is
        # `enrollments` -- and the connection between the two is a foreign key,
        # not anything visible here.
        #
        # enrollments_session_id_fkey makes every INSERT into enrollments take
        # FOR KEY SHARE on the referenced sessions row, and FOR KEY SHARE
        # conflicts with FOR UPDATE. So holding this lock blocks every
        # concurrent enrollment insert for these sessions, including from code
        # paths that have never heard of it. That is what stops two settlements
        # both reading 'none' from cart_seat_state and both inserting, which
        # would raise inside a captured settlement.
        #
        # Two consequences worth knowing before touching either side. Dropping
        # or deferring that FK silently removes the mutual exclusion while this
        # statement still looks like it provides it. And the protection covers
        # INSERTs only: an UPDATE that changes `status` without touching
        # `session_id` takes no lock here, so flipping a cancelled row back to
        # live races this freely. Nothing in lib/ does that today -- there is no
        # caller of the enrollment activate/pend helpers -- which is the only
        # reason it is not a live defect. See #327.
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

        # Children this registration chose to wait for rather than be turned
        # away. No money attaches to them -- they have no seat -- so this sits
        # above the enrollment_items guard: a cart can be all waiting and
        # nothing else, and the queue is still what the parent asked for.
        #
        # Here rather than in the workflow step because the parent who pays and
        # closes the tab never comes back to the step; the
        # payment_intent.succeeded webhook settles them, and it lands here.
        require Registry::DAO::Waitlist;
        Registry::DAO::Waitlist->join_items( $db, $user_id,
            ( ref $metadata eq 'HASH' && ref $metadata->{waitlist_items} eq 'ARRAY' )
            ? $metadata->{waitlist_items}
            : [] );

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
            # a share another system has already returned. An earlier delivery's
            # own demotion lands here too -- it releases the seat it is giving
            # up -- so this is what stops a redelivery owing that share twice.
            next if $held eq 'closed';

            # A row off its seat but not released -- what Enrollment->waitlist
            # writes. No settlement path produces one (demotion releases the
            # seat, and lands on 'closed' above), so this is a row somebody
            # else put here. Re-adjudicating cannot promote it --
            # create_for_payment conflicts on (session_id, student_id,
            # payment_id) against the very row and does nothing -- but it would
            # still credit %granted for a seat that was never created and send a
            # confirmation email to a family whose child is not enrolled. The
            # phantom grant then under-counts capacity for the next item in
            # this session, which is the defect the pre-pass above exists to
            # prevent, reintroduced one item at a time.
            next if $held eq 'waitlisted';

            # The child already holds a live seat from another payment, so there
            # is nothing to seat -- and trying would collide with the live-only
            # uniqueness rule, inside a settlement Stripe has already captured.
            # This cart paid for a seat it did not need, so its share is owed
            # back. Not demoted: there is no row of ours to demote, and the row
            # that exists belongs to whoever paid for it first.
            if ( $held eq 'foreign' ) {
                # Only the READ goes in the try. Putting the marker INSERT in
                # here as well looked tidier and is a trap: any database error
                # on that insert -- deadlock, serialization failure, a
                # statement_timeout cancel, a trigger -- aborts the surrounding
                # transaction, and the catch's first act is to UPDATE payments,
                # which cannot run on an aborted transaction. It dies there, so
                # the genuine error never reaches the warn below, no
                # manual-review flag is written, and the webhook 500s into a
                # retry loop reproducing it forever. Three failures for one
                # fault, and the one piece of evidence a human needs is the part
                # that gets destroyed.
                my $share = $self->_share_or_flag(
                    $db, $item->{child_id}, $session_id, 'duplicate-seat share' );

                # The marker is recorded only once the debt it stands for
                # resolves, and both halves of that carry weight.
                #
                # Recording it makes the branch idempotent: cart_seat_state
                # reads our own cancelled row as 'closed' next delivery, so the
                # child is not owed for twice. Without it every redelivery owes
                # the same child again under a fresh refund_seq -- a fresh
                # Stripe idempotency key, which Stripe does not deduplicate.
                #
                # Recording it only on success keeps an unresolvable share
                # resolvable: while the state stays 'foreign' a later delivery
                # looks at this child again, so supplying the missing line item
                # settles it. The manual-review flag is what stops the cart
                # settling clean in the meantime.
                #
                # A cancelled row is the honest record -- this cart paid for a
                # seat it did not receive -- and it sits outside
                # enrollments_session_student_type_live, so it cannot collide
                # with the seat the other payment holds. drop_reason is set
                # because this is not a drop: the unfiltered admin readers would
                # otherwise show a family dropping a session their child is
                # still attending.
                #
                # If this insert fails there is no marker and no debt, the error
                # propagates, and the redelivery retries the whole item -- which
                # is right, because a marker we could not write is a promise we
                # cannot keep.
                if ( defined $share ) {
                    Registry::DAO::Enrollment->create_for_payment( $db, {
                        session_id       => $session_id,
                        family_member_id => $item->{child_id},
                        parent_id        => $user_id,
                        status           => 'cancelled',
                        payment_id       => $id,
                        drop_reason      => 'duplicate_seat_refunded',
                    } );

                    $owed_cents += $share;
                    push @owed_children, $item->{child_id};
                }

                next;
            }

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
                    # Flagged, not left on $metadata for a later save(): the
                    # obligation writer stopped calling save() when the debt
                    # moved to typed columns, so an in-memory flag would never
                    # reach the row, and a cart whose ONLY problem is an
                    # unpriced child would settle looking clean with nothing for
                    # the runbook to find.
                    my $share = $self->_share_or_flag(
                        $db, $item->{child_id}, $session_id, 'refund share' );
                    if ( defined $share ) {
                        $owed_cents += $share;
                        push @owed_children, $item->{child_id};
                    }
                }
                next;
            }

            my $enrollment_id = Registry::DAO::Enrollment->create_for_payment($db, {
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
                    user_id       => $user_id,
                    session_id    => $session_id,
                    child_id      => $item->{child_id},
                    enrollment_id => $enrollment_id,
                });
            }
            catch ($e) {
                warn "finalize_enrollment: enrollment confirmation failed for session $session_id (payment $id): $e";
            }
        }

        # Close the waitlist offers this cart redeemed, now that the seats are
        # actually written. Done here rather than at acceptance: until the money
        # lands the seat is only promised, and a row marked 'accepted' early stops
        # holding the seat it is still reserving (Enrollment::offered_seats_held).
        #
        # Only offers whose child this pass actually seated: a cart that lost the
        # seat to the capacity gate leaves its offer open, so the family can be
        # offered again rather than holding an accepted row for a seat they never
        # got.
        if ( ref $metadata eq 'HASH'
             && ref $metadata->{accepted_offer_ids} eq 'ARRAY'
             && @{ $metadata->{accepted_offer_ids} } ) {
            require Registry::DAO::Waitlist;

            my @seated = $db->query( q{
                SELECT w.id
                  FROM waitlist w
                  JOIN enrollments e
                    ON e.session_id = w.session_id
                   AND e.student_id = w.student_id
                 WHERE w.id = ANY(?::uuid[])
                   AND e.payment_id = ?
                   AND e.status = ANY(?)
            }, $metadata->{accepted_offer_ids}, $id,
               Registry::DAO::Enrollment->seat_holding_statuses
            )->arrays->flatten->to_array->@*;

            Registry::DAO::Waitlist->mark_accepted( $db, \@seated ) if @seated;
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

        # The flag is written whatever the STATUS says -- the case that most
        # needs recording is a debt on a row that already reached a terminal
        # refund status, since that debt cannot be represented as an obligation
        # at all. An earlier version guarded the whole statement on the status,
        # so exactly that case wrote nothing anywhere.
        #
        # It is guarded on the PAIR, though, because the same fault recurs. The
        # duplicate-seat branch deliberately writes no marker row when the share
        # is unresolvable, so the state stays 'foreign' and every later delivery
        # re-enters -- and finalize_enrollment does not early-return on
        # refund_pending, so a parent refreshing the Stripe return URL re-enters
        # it too. Appending unconditionally grew this array without bound on a
        # money row, and made the runbook read one fault as N.
        my $entry = encode_json([ { child_id => $child_id, session_id => $session_id } ]);
        $db->query( <<'SQL', $entry, $id, $entry );
            UPDATE payments
               SET metadata = jsonb_set( COALESCE(metadata, '{}'::jsonb),
                       '{refund_manual_review}',
                       COALESCE(metadata->'refund_manual_review', '[]'::jsonb) || ?::jsonb )
             WHERE id = ?
               AND NOT COALESCE(metadata->'refund_manual_review', '[]'::jsonb)
                       @> ?::jsonb
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

    # One dropped seat is one refund. Keyed on the enrollment rather than a
    # counter because the drop is the event being paid for: re-driving the
    # workflow, or an admin pressing approve twice, reuses the key and Stripe
    # returns the original refund instead of making a second one.
    method drop_refund_key ($enrollment_id) {
        return "refund:drop:$id:$enrollment_id";
    }

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

        # Every reference to the increment is CORRELATED against the target
        # tuple, and the guard is an EXISTS in the WHERE rather than a CTE join.
        #
        # A CTE is materialised from the statement's snapshot. Under READ
        # COMMITTED a blocked UPDATE re-evaluates correlated subqueries against
        # the updated row via EvalPlanQual, but NOT a CTE -- so with a CTE, two
        # overlapping settles of one seq left the jsonb rewrite correctly
        # no-opping while the arithmetic still applied a stale amount. 3000
        # reached Stripe and the row recorded 6000 returned, silently, with the
        # caller's zero-row branch never firing. The bare arithmetic it replaced
        # at least aborted loudly on the CHECK.
        #
        # SUM, because the jsonb rewrite below marks EVERY element with this seq
        # settled: subtracting one of a duplicated pair would leave a balance
        # nothing can discharge. The EXISTS makes "no unsettled increment with
        # this seq" report zero rows, which is the contract both callers' "matched
        # no row after Stripe paid" branch depends on.
        my $row = $db->query( <<'SQL', $seq, $refund->{id}, $seq, $seq, $id, $seq )->hash;
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
                   refund_owed_cents = GREATEST( 0, p.refund_owed_cents - COALESCE( (
                       SELECT SUM((e->>'cents')::int)
                         FROM jsonb_array_elements(p.refund_increments) e
                        WHERE (e->>'seq')::int = ? AND e->>'settled_at' IS NULL ), 0) ),
                   refunded_cents = LEAST( p.amount_cents, p.refunded_cents + COALESCE( (
                       SELECT SUM((e->>'cents')::int)
                         FROM jsonb_array_elements(p.refund_increments) e
                        WHERE (e->>'seq')::int = ? AND e->>'settled_at' IS NULL ), 0) )
             WHERE p.id = ?
               AND EXISTS ( SELECT 1 FROM jsonb_array_elements(p.refund_increments) e
                             WHERE (e->>'seq')::int = ? AND e->>'settled_at' IS NULL )
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
            # Which plan version set this price. Nullable: line items are also
            # written for things no plan priced, and a historical row must not
            # start failing because a plan family was pruned.
            pricing_plan_id => $args->{pricing_plan_id},
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
    

    # status = 'failed', with its legality in the WHERE. Three call sites wrote
    # this: the two intent-creation failures and the retrieval failure. Each
    # guarded it differently -- one with _guard_settled_write, one with
    # _money_has_moved, one not at all -- which is how a failure branch once
    # routed into the success path. One writer, one predicate.
    method _record_intent_failure_write ($db, $error) {
        $db = $db->db if $db isa Registry::DAO;

        my $from  = __CLASS__->_legal_predecessors('failed');
        my $moved = $db->query( <<'SQL', $error, $id, $from )->rows;
            UPDATE payments
               SET status = 'failed', error_message = ?
             WHERE id = ? AND status = ANY(?)
SQL
        return 0 unless $moved;

        $status        = 'failed';
        $error_message = $error;
        return 1;
    }

    # status = 'processing'. Same shape; only pending may precede it.
    method _record_processing ($db) {
        $db = $db->db if $db isa Registry::DAO;

        my $from  = __CLASS__->_legal_predecessors('processing');
        my $moved = $db->query( <<'SQL', $id, $from )->rows;
            UPDATE payments SET status = 'processing'
             WHERE id = ? AND status = ANY(?)
SQL
        return 0 unless $moved;
        $status = 'processing';
        return 1;
    }

    # The intent id, which is not a status transition: it is legal exactly while
    # the money has not moved. Named alone, so it cannot restore five other
    # columns from a stale object on its way past.
    method _record_intent_id ($db, $intent_id) {
        $db = $db->db if $db isa Registry::DAO;

        my $moved = $db->query( <<'SQL', $intent_id, $id, __CLASS__->_settled_statuses )->rows;
            UPDATE payments SET stripe_payment_intent_id = ?
             WHERE id = ? AND NOT (status = ANY(?))
SQL
        return 0 unless $moved;
        $stripe_payment_intent_id = $intent_id;
        return 1;
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
    method mark_completed ($db, $payment_intent_id, $payment_method_id = undef) {
        $db = $db->db if $db isa Registry::DAO;

        # Names three columns and carries its own legality. Zero rows is the
        # refusal, by construction -- no lock, no prior read, and no return
        # shape a caller can misread as success. save() wrote six columns from
        # the in-memory object, so a walk-back was a restore of whatever that
        # object last held.
        my $from  = __CLASS__->_legal_predecessors('completed');
        # All binds on the <<'SQL' line: a continuation line after it is
        # swallowed into the heredoc body.
        my @bind = ( $payment_intent_id, $payment_method_id, $id, $from );
        my $moved = $db->query( <<'SQL', @bind )->rows;
            UPDATE payments
               SET status = 'completed',
                   stripe_payment_intent_id = ?,
                   -- COALESCE, so a caller with no method in hand does not
                   -- erase one already recorded. save() carried this column and
                   -- the first conversion dropped it entirely, silently.
                   stripe_payment_method_id = COALESCE(?, stripe_payment_method_id),
                   completed_at = NOW()
             WHERE id = ?
               AND status = ANY(?)
SQL
        return 0 unless $moved;

        $status                   = 'completed';
        $stripe_payment_intent_id = $payment_intent_id;
        $stripe_payment_method_id = $payment_method_id if $payment_method_id;
        return $self;
    }

    # Replace the idempotency token with a fresh UUID and persist immediately.
    # Call this before retrying a declined intent so the retry is a genuinely
    # new Stripe charge rather than a duplicate of the failed one.
    # The token, alone. Legal exactly while the money has not moved -- and the
    # refusal is the same statement as the write, so nothing can settle between
    # the two.
    method rotate_idempotency_token ($db) {
        $db = $db->db if $db isa Registry::DAO;

        # One statement: generate, merge into the jsonb, and refuse a settled
        # row -- rather than read, decide, then save six columns from an object
        # that may have gone stale in between. Returns the new token, or undef
        # if the row was settled.
        my $row = $db->query( <<'SQL', $id, __CLASS__->_settled_statuses )->hash;
            UPDATE payments
               SET metadata = jsonb_set( COALESCE(metadata, '{}'::jsonb),
                       '{idempotency_token}', to_jsonb(gen_random_uuid()::text) )
             WHERE id = ? AND NOT (status = ANY(?))
         RETURNING metadata->>'idempotency_token' AS token
SQL
        return unless $row;

        $metadata->{idempotency_token} = $row->{token};
        return $row->{token};
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
    # Resolve one child's share, or flag it for a human and return undef.
    #
    # Wrapped in a SAVEPOINT because the callers run inside a transaction --
    # Webhooks opens one, and process_payment_async opens one around the
    # parent-return callback. A statement that fails at the DATABASE level
    # (statement_timeout cancel, deadlock, serialization failure, a trigger)
    # aborts that transaction, after which every further statement on the
    # connection is refused. The catch's job is to write a manual-review flag,
    # which is a statement, so without the savepoint the recovery path is itself
    # refused: the real cause is replaced by "current transaction is aborted",
    # no flag is written, and the warn never runs because it sits after the
    # write. Three failures for one fault, and the evidence a human needs is the
    # part destroyed.
    #
    # The guard is conditional because a savepoint outside a transaction is an
    # error in its own right, and the tests -- like any autocommit caller --
    # have no enclosing transaction. There, a failed statement poisons nothing
    # and no savepoint is wanted.
    #
    # The warn comes FIRST. If the flag write fails for any reason, the cause
    # has already reached the log.
    method _share_or_flag ($db, $child_id, $session_id, $what) {
        $db = $db->db if $db isa Registry::DAO;

        my $in_txn = !$db->dbh->{AutoCommit};
        $db->query('SAVEPOINT registry_share_lookup') if $in_txn;

        my $share;
        try {
            $share = $self->refund_share_for( $db, $child_id, $session_id );
            $db->query('RELEASE SAVEPOINT registry_share_lookup') if $in_txn;
        }
        catch ($e) {
            if ($in_txn) {
                # ROLLBACK TO undoes the failed statement but LEAVES the
                # savepoint defined; without the RELEASE a cart re-issuing the
                # same name once per child stacks a subtransaction per failure.
                $db->query('ROLLBACK TO SAVEPOINT registry_share_lookup');
                $db->query('RELEASE SAVEPOINT registry_share_lookup');
            }
            warn "finalize_enrollment: unresolvable $what for child $child_id "
               . "in session $session_id (payment $id): $e";
            $self->flag_refund_manual_review( $db, $child_id, $session_id );
        }
        return $share;
    }

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

        # Refuse a negative share HERE, where both accumulation sites route
        # through it, rather than at the obligation writer. That writer guards
        # the cart TOTAL, so one child's negative share silently cancelled
        # another child's real debt: +5000 and -2000 recorded 3000, tripped no
        # guard, wrote no manual-review flag and warned nobody, leaving the
        # child who actually lost their seat under-refunded by 2000 with
        # nothing to find. Reachable because PricingPlan's percentage_discount
        # is unbounded and payment_items.amount_cents carries no CHECK.
        # Dying here reaches the caller's catch, which flags for review.
        die "refund_share_for: negative share $row->{cents} for child "
          . "$child_id in session $session_id on payment $id\n"
            if $row->{cents} < 0;

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
    # Which statuses may precede which, for the writes on the intent path.
    #
    # It covers those three and no more. An earlier version listed
    # refund_pending, refunded and partially_refunded too, which no writer
    # consulted and which contradicted the predicates the real refund writers
    # use -- record_capacity_obligation and _apply_refund_result carry headroom
    # and increment conditions this table cannot express. A table that is half
    # documentation and half false is worse than a smaller true one, in the
    # place a future author will trust.
    #
    # This is what section 2.3 of the settlement spec keeps from the state
    # table: a pure predicate, not a god-method taking an untyped column bag
    # through which {status => 'completed'} would bypass the machine entirely.
    # Each write still names its own columns; only legality is shared.
    sub _legal_predecessors ($class, $to = undef) {
        # 'failed' is NOT terminal here, and treating it as such strands
        # captured money. _apply_intent writes 'failed' for any intent status it
        # does not recognise -- including requires_action, an ordinary 3DS
        # payment mid-authentication -- and the decline-retry path deliberately
        # reuses the same row rather than orphaning it. Both legitimately reach
        # completed when the money lands. Refusing that leaves a charge Stripe
        # took sitting at 'failed' with completed_at NULL, outside
        # _refundable_status and so unrefundable forever, while
        # finalize_enrollment still seats the child.
        #
        # failed -> failed is legal because each decline must record its own
        # reason; refusing it showed the parent the previous card's error.
        state $graph = {
            processing         => [qw( pending failed )],
            completed          => [qw( pending processing failed )],
            failed             => [qw( pending processing failed )],
        };
        return $graph unless defined $to;
        # die, not `// []`. An empty list makes `status = ANY('{}')` -- a writer
        # that refuses every row, silently, which is the worst possible response
        # to a typo in a status name.
        return $graph->{$to} // die "no transition rule for status '$to'\n";
    }

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
                       -- Same re-check as the status above. Guarding only the
                       -- status let refunded_cents consume the whole cart while
                       -- a debt recorded mid-round-trip survived beside it:
                       -- owed + refunded then exceeds amount_cents, which is the
                       -- shape verify treats as fatal, and the increment loop
                       -- POSTs against a fully-refunded intent forever.
                       WHEN refund_owed_cents > 0 THEN refunded_cents
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
    
    # The child a cart line is charging for, named from whichever keys the
    # snapshot happens to carry.
    #
    # family_members has one child_name column; first_name and last_name appear
    # in no migration. MultiChildSessionSelection synthesises them anyway --
    # first_name gets the whole child_name and last_name the empty string -- so
    # interpolating both put two spaces before the dash, and any caller passing
    # a row straight off the family tables interpolated two undefs instead:
    # a description reading " - Pottery Week", and two uninitialized-value
    # warnings for every item on every receipt.
    my sub _child_label ($child) {
        my $name = $child->{child_name};
        return $name if defined $name && length $name;

        return join ' ', grep { defined && length }
          $child->{first_name}, $child->{last_name};
    }

    sub calculate_enrollment_total ($class, $db, $enrollment_data) {
        my $total = 0;
        my $items = [];
        
        # Import Session class
        require Registry::DAO::Session;
        require Registry::DAO::PricingPlan;

        my $children = $enrollment_data->{children} // [];

        # How many children are in THIS cart, which is the question a family or
        # sibling plan's min_children asks. It was hardcoded to 1, so no family
        # plan could ever be satisfied and the MVP's sibling discount was
        # unreachable through the cart -- the plan type exists, the schema allows
        # it, and nothing could ever qualify for it.
        my $child_count = scalar @$children;

        # The plans this cart is actually priced by, collected so the instalment
        # offer can be decided from all of them together rather than per line.
        my @plans;

        # Calculate cost for each child-session pair
        for my $child (@$children) {
            my $child_key = $child->{id} || 0;
            my $session_id = $enrollment_data->{session_selections}->{$child_key} 
                          || $enrollment_data->{session_selections}->{all};
            
            next unless $session_id;
            
            my $session = Registry::DAO::Session->find($db, { id => $session_id });
            next unless $session;

            # The cheapest plan whose requirements this cart MEETS. get_best_price
            # was written for exactly this and was not being called.
            #
            # Taking $pricing_plans->[0] charged whichever row Postgres happened
            # to hand back first -- get_pricing_plans has no ORDER BY, so one cart
            # could be priced differently between two runs. Worse, when that row
            # was an early bird past its cutoff, calculate_price correctly
            # returned undef and the child was then skipped altogether: no line
            # item, nothing added to the total, and still sitting in
            # enrollment_items. Enrolled, and charged nothing.
            my ( $plan, $price_cents ) = Registry::DAO::PricingPlan->best_plan(
                $db, $session_id,
                { child_count => $child_count, date => time(), %$child }
            );

            if (defined $price_cents) {
                $total += $price_cents;
                push @plans, $plan if $plan;

                # A nameless child still gets a line naming the session, rather
                # than one that opens with a dangling separator.
                my $label = _child_label($child);

                push @$items, {
                    description => $label
                      ? "$label - " . $session->name
                      : $session->name,
                    amount_cents => $price_cents,
                    # The plan VERSION this price came from. The pricing basis of
                    # a charge was recorded nowhere: an amount does not say which
                    # plan produced it, so neither a dispute nor a pricing
                    # experiment could be settled after the fact.
                    pricing_plan_id => $plan ? $plan->id : undef,
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
            schedule_options =>
                _schedule_options( $db, $total, \@plans ),
        };
    }

    # The ways this cart may be paid: always in full, and in instalments when
    # every priced line agrees on the same schedule.
    #
    # Agreement is the rule because a cart is ONE charge. Offering instalments
    # for the part of a cart that allows them would mean two Stripe objects, two
    # failure modes and a statement no parent could read -- so a cart whose lines
    # disagree is paid in full, which every plan permits.
    sub _schedule_options ( $db, $total_cents, $plans ) {
        my @options = ( { key => 'full', label => 'Pay in full',
                          instalments => [ { amount_cents => $total_cents,
                                             due_date     => undef } ] } );

        # Nothing to split, and no plan to split it by.
        return \@options unless $total_cents > 0 && @$plans;

        my @declared = map { $_->payment_schedule } @$plans;
        return \@options if grep { !defined } @declared;

        # Identical terms, not merely "all present". Three instalments and four
        # do not reconcile into a single schedule, and picking one of them would
        # charge somebody terms they were not shown.
        my $first = $declared[0];
        for my $d (@declared) {
            return \@options
                unless $d->{count} == $first->{count}
                    && $d->{cadence} eq $first->{cadence}
                    && $d->{surcharge_pct} == $first->{surcharge_pct};
        }

        # Resolved through the plan, so the arithmetic that keeps every cent has
        # exactly one home.
        my $instalments = $plans->[0]->instalment_schedule($total_cents)
            or return \@options;

        push @options, {
            key         => 'instalments',
            label       => sprintf( 'Pay in %d %s instalments',
                             $first->{count}, $first->{cadence} ),
            instalments => $instalments,
        };

        return \@options;
    }
    
    # Async payment methods. These are what the web request path uses: a
    # blocking Stripe call inside the running IOLoop can never settle, because
    # Mojo::Promise::wait is a no-op once its loop is already running.
    method create_payment_intent_async ($db, $args = {}) {
        # The customer is resolved INSIDE the chain. _intent_params is called
        # synchronously, so anything it needed from the network would be a
        # blocking call in the live IOLoop -- which is what #284 was: a parent
        # choosing instalments could not check out, because _await can never
        # settle once the loop is running.
        # Only an instalment needs one. Resolving unconditionally would mint a
        # Stripe customer for every one-off enrolment, which is a cost and a
        # mess rather than a bug -- and is what the one-off subtest pins.
        my $customer = $self->is_instalment
            ? $self->_stripe_customer_async($db)
            : Mojo::Promise->resolve(undef);

        return $customer->then( sub ($customer_id) {
            $self->stripe_client->create_payment_intent_async(
                $self->_intent_params( $db, $args, $customer_id )
            );
        } )->then(
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
    
    # Every failure before the request is dispatched carries this. Nothing
    # downstream of create_refund_async may use it.
    use constant REFUND_NOT_SENT => 'REFUND_NOT_SENT';

    # Did this failure happen before anything was sent to Stripe?
    #
    #   not_sent -- certain. No request was dispatched, so no money moved, and
    #               the runbook's list-refunds-before-issuing step is wasted.
    #   unknown  -- everything else. A Stripe error response and a response
    #               that was lost look the same from here, and both are
    #               reported as unknown rather than guessed at: claiming a
    #               refund failed when it succeeded invites a second one.
    sub classify_refund_failure ($class, $err) {
        my $marker = REFUND_NOT_SENT;
        return 'not_sent' if defined $err && $err =~ /\Q$marker\E/;
        return 'unknown';
    }

    # The log is where an operator looks second; the row is where the runbook
    # looks first. Best-effort: a stamp that cannot be written must not turn a
    # refund failure into a second failure on top of it.
    method record_refund_failure ($db, $err) {
        $db = $db->db if $db isa Registry::DAO;

        my $record = {
            classification => __CLASS__->classify_refund_failure($err),
            message        => "$err",
            at             => time(),
        };

        eval {
            $db->query(
                q{UPDATE payments
                     SET metadata = COALESCE(metadata, '{}'::jsonb) || ?::jsonb
                   WHERE id = ?},
                encode_json( { refund_last_failure => $record } ), $id
            );
            1;
        } or warn "could not record refund failure on payment $id: $@";

        return $record;
    }

    method refund_async ($db, $args = {}) {
        # Every sibling opens with this. refund_async did not, and round 3 added
        # a raw $db->query here -- Registry::DAO::query returns a plain hashref,
        # so a DAO handle (which WorkflowProcessor passes straight through) threw
        # method-not-found inside the workflow step's ->catch, where it is a
        # silent warn and no refund.
        $db = $db->db if $db isa Registry::DAO;

        # Marked, because what an operator needs to know first is whether any
        # money can have moved, and for these it certainly cannot: the request
        # is never dispatched. Classifying on a marker rather than on wording --
        # Stripe's or ours -- keeps that answer from turning on a message
        # somebody reworded.
        die REFUND_NOT_SENT . ": Cannot refund a payment with status '$status'"
            unless __CLASS__->_refundable_status($status);
        die REFUND_NOT_SENT . ": No Stripe payment intent ID"
            unless $stripe_payment_intent_id;

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
            die REFUND_NOT_SENT . ": Cannot issue a direct refund while $owed "
              . "cents of capacity debt is outstanding on payment $id\n" if $owed;
        }

        return $self->stripe_client->create_refund_async({
            payment_intent => $stripe_payment_intent_id,
            amount         => $refund_cents,
            reason         => $reason,
            $self->_refund_connect_params($db),
            $args->{idempotency_key}
                ? ( _idempotency_key => $args->{idempotency_key} ) : (),
        })->then(sub ($refund) {
            # Told, not inferred. This used to read the presence of an
            # idempotency key as "this is a capacity increment", because at the
            # time only increments carried one. They are two independent
            # decisions -- whether settle_refund_increment owns the status, and
            # whether a retry is safe -- and a direct refund that wants
            # idempotency (a dropped seat, #286) was silently accounted as an
            # increment, so refunded_cents never moved and the ledger denied a
            # refund the bank had made.
            $self->_apply_refund_result( $db, $refund, $refund_cents, $reason,
                $args->{increment} ? 1 : 0 );
            return $refund;
        })->catch(sub ($error) {
            die "Refund failed: $error";
        });
    }
}

1;