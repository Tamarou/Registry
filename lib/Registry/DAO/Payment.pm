use 5.42.0;
use warnings;


use Object::Pad;
class Registry::DAO::Payment :isa(Registry::DAO::Object) {

use Registry::Service::Stripe;
use Registry::PriceOps::RevenueShare;
use Registry::PriceOps::PlatformTerms ();
use Mojo::JSON qw(encode_json from_json);
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

# What the platform took on this charge, and the platform offer version and
# payment plan it took it under. NULL means NOT RECORDED -- every charge made
# before these columns existed, and any charge with no seller account. Zero
# would claim the platform took nothing, which is a different and sometimes
# false statement.
field $platform_fee_cents        :param :reader = undef;
field $platform_offer_version_id :param :reader = undef;
field $platform_payment_plan_id  :param :reader = undef;

# The seller's offer version this charge was sold under, in the payment's own
# schema. NULL for after-school cart payments; fixed once set (by the database).
field $offer_version_id :param :reader = undef;
field $platform_fee_refunded_cents :param :reader = undef;
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

# The entitlement an instalment (2..N) or change payment was paid towards;
# NULL on the charge that created entitlements, which they name instead.
field $entitlement_id :param :reader = undef;

# True when this row is one of several. Asked rather than derived at each call
# site, so nothing has to remember that the pair is all-or-nothing.
method is_instalment { return defined $instalment_seq ? 1 : 0 }

field $_stripe_client = undef;
    
    ADJUST {
        # Decode JSON metadata if it's a string
        if (defined $metadata && !ref $metadata) {
            try {
                $metadata = from_json($metadata);
            } catch ($e) {
                $metadata = {};
            }
        }
    }
    
    sub table { 'payments' }

    # Platform revenue share, collected at charge time as a Stripe application
    # fee on the destination charge. The fraction is resolved from the tenant's
    # plan by the caller. Integer cents, rounded half to even (ruling 7c).
    # Computed in integers: the rate as whole basis points (plans are saved to
    # at most 4 decimals, PricingPlan), so a half cent is exactly a half cent.
    sub application_fee_cents ($amount_cents, $fraction) {
        my $bp = sprintf '%.0f', $fraction * 10_000;
        die "revenue share $fraction is finer than a basis point\n"
            if abs( $fraction * 10_000 - $bp ) > 1e-6;
        my $n = $amount_cents * $bp;
        my ( $q, $r ) = ( int( $n / 10_000 ), $n % 10_000 );
        $q++ if $r > 5_000 || ( $r == 5_000 && $q % 2 );
        return $q;
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

    # Stripe's recurring interval for a plan's cadence: [ interval, count ].
    my %RECURRING = ( weekly => [ week => 1 ], monthly => [ month => 1 ], quarterly => [ month => 3 ] );

    # The subscription-schedule request for one child's instalments still to
    # come, on $args->{cadence}, naming $args->{entitlement_id}.
    #
    # Instalment one is taken on-session at checkout, where the parent is
    # present to satisfy a card challenge and the card is saved; this covers
    # what is left, charged automatically against that card.
    #
    # `start` is instalment_schedule_start's choice. `second_due` starts it on
    # part two's due date. `now` starts it at once (on the checkout date) with
    # a $0 period for the part already paid, so its anchor is the checkout
    # day. Either way no phase prorates or moves the anchor, so Stripe charges
    # the stored due dates, in at most three phases however many parts.
    sub instalment_schedule_params ( $args ) {
        my $recurring = $RECURRING{ $args->{cadence} // '' }
            or die "no Stripe interval for cadence '" . ( $args->{cadence} // '' ) . "'\n";
        my $instalments = $args->{instalments} // [];
        my $currency    = lc( $args->{currency} // 'usd' );
        my $product     = $args->{product};

        my $phases = instalment_phases(
            $instalments, $currency, $args->{description} // 'Enrollment' );
        my $now = ( $args->{start} // '' ) eq 'now';
        unshift @$phases, { %{ $phases->[0] }, unit_amount => 0, iterations => 1 } if $now;

        my %params = (
            customer   => $args->{customer},
            start_date => $now ? 'now' : _epoch_for_date( $instalments->[0]{due_date} ),

            # It ends. An instalment plan is a fixed number of charges, and a
            # schedule that renewed would bill a family for a camp that finished
            # in August, every August.
            end_behavior => 'cancel',

            'default_settings[collection_method]'     => 'charge_automatically',
            'default_settings[default_payment_method]' => $args->{payment_method},

            # No transfer_data: the schedule is made on the seller's own account
            # (a direct charge, as the one-off path is), so the money is
            # already theirs and our share is the application fee.

            # So an invoice that beats the rows' COMMIT is retried, not ignored
            # (Webhooks::_schedule_not_recorded).
            'metadata[entitlement_id]' => $args->{entitlement_id},
        );

        # Omitted rather than sent as zero. A tenant on a 0% platform offer owes no
        # revenue share, and an explicit 0 is a value Stripe has no reason to
        # accept on a schedule that takes no fee.
        # Fixed to two places and trimmed: Stripe refuses a third decimal here
        # (t/stripe-live/schedule-fee-precision.t), and plans are saved to at
        # most 2 (PricingPlan::_check_rate), so this only trims float noise; and
        # Perl would write a small rate as 1e-02 and float noise in full.
        ( my $pct = sprintf '%.2f', $args->{revenue_share_pct} // 0 ) =~ s/\.?0+\z//;
        $params{'default_settings[application_fee_percent]'} = $pct if $pct > 0;

        for my $i ( 0 .. $#$phases ) {
            my $p = $phases->[$i];
            $params{"phases[$i][iterations]"} = $p->{iterations};
            $params{"phases[$i][proration_behavior]"} = 'none';
            $params{"phases[$i][items][0][price_data][currency]"}    = $p->{currency};
            $params{"phases[$i][items][0][price_data][unit_amount]"} = $p->{unit_amount};
            # A product id, not product_data. Stripe refuses inline product
            # data inside a schedule phase's price_data -- "Received unknown
            # parameter: product_data. Did you mean product?" -- so the caller
            # creates the product and passes its id.
            $params{"phases[$i][items][0][price_data][product]"} = $product;
            $params{"phases[$i][items][0][price_data][recurring][interval]"}       = $recurring->[0];
            $params{"phases[$i][items][0][price_data][recurring][interval_count]"} = $recurring->[1];
        }

        return \%params;
    }

    # Is $invoice the $0 opening period a schedule bills for the part paid at
    # checkout? Its first invoice, priced at nothing before any credit or
    # discount. Not amount_due: an instalment paid from credit balance or
    # under a 100% coupon is due nothing and is still that month's.
    sub is_opening_invoice ( $invoice ) {
        my $subtotal = $invoice->{subtotal};
        return ( $invoice->{billing_reason} // '' ) eq 'subscription_create'
            && defined $subtotal && !ref $subtotal && $subtotal eq '0' ? 1 : 0;
    }

    # How a schedule for $parts (part one paid at checkout) on $cadence must
    # start, made on UTC date $today, for Stripe to charge exactly the stored
    # due dates: 'second_due', 'now', or undef when no start can.
    #
    # Stripe bills on its anchor's day, clamped to shorter months ("a billing
    # cycle anchor date of January 31 bills ... February 28 ..., then March
    # 31, April 30"), and a schedule anchors where it starts. From part two's
    # date that is exact when counting on from it gives the stored dates:
    # weekly, or a day of the month a shorter month never clamps. A Jan 31
    # plan's Feb 28 would go on to Mar 28, so it starts now, which anchors on
    # the 31st only on the checkout date itself. Never backdated: Stripe bills
    # the elapsed time of a past start. Nothing starts once part two is due,
    # as it could bill a missed period at once.
    sub instalment_schedule_start ( $cadence, $parts, $today ) {
        my @later = @{$parts}[ 1 .. $#$parts ];
        return undef if !@later || $today ge $later[0]{due_date};
        require Registry::PriceOps::Instalments;
        my $counted = Registry::PriceOps::Instalments::due_dates(
            { count => scalar @later, cadence => $cadence }, $later[0]{due_date} );
        return 'second_due' if "@$counted" eq join ' ', map { $_->{due_date} } @later;
        return $today eq $parts->[0]{due_date} ? 'now' : undef;
    }

    # YYYY-MM-DD to an epoch second, which is what Stripe takes. Noon UTC rather
    # than midnight, so a timezone offset cannot move a due date onto the
    # previous day and charge a family a month early.
    sub _epoch_for_date ( $date ) {
        return time() unless defined $date && $date =~ /^(\d{4})-(\d{2})-(\d{2})$/;
        require Time::Local;
        return Time::Local::timegm_posix( 0, 0, 12, $3, $2 - 1, $1 - 1900 );
    }

    # Create the Stripe schedule for $entitlement's instalments after the
    # first, and record each of them as a payments row naming it. $self is
    # the cart charge that made $entitlement and took its part one: its
    # metadata.lines hold the parts, and its customer and saved card pay the
    # rest. Each child on instalments has a schedule of its own, so a missed
    # payment, drop or transfer acts on that child alone. The schedule id, or
    # undef when its line is not paid in instalments.
    #
    # Called from a job rather than at checkout, for two reasons. The card
    # only exists once the cart charge has succeeded; and a blocking Stripe
    # call inside a transaction is the shape of #284 -- the work belongs
    # after the COMMIT, where a failure can be retried without holding a lock.
    #
    # Idempotent three ways, because a second schedule bills the family twice.
    # A run that finds rows recorded for the entitlement returns their
    # schedule. Runs for one entitlement are serialised by an advisory lock,
    # and the check is made under it, so a second job waits for the first and
    # then finds its schedule. And the product and schedule creates carry
    # Idempotency-Keys named for the entitlement, so a retry after Stripe made
    # the schedule but before our COMMIT gets that same schedule back.
    # And Stripe is asked for a schedule an earlier run made before another is
    # created, as a key does not always answer that: Stripe replays a stored
    # 500 under it for 24 hours, and forgets it after.
    method schedule_instalments_for ( $db, $entitlement ) {
        my $raw = ($db isa Registry::DAO) ? $db->db : $db;
        my $eid = $entitlement->id;
        die "entitlement $eid was not made by payment $id\n"
            unless ( $entitlement->payment_id // '' ) eq $id;

        my $line = $self->_line_for( $raw, $entitlement );
        return undef unless $line && ( $line->{kind} // '' ) eq 'instalments';
        my @parts     = @{ $line->{parts} // [] };
        my @remaining = @parts[ 1 .. $#parts ];
        return undef unless @remaining;

        my $meta = $metadata // {};
        my $slug = $meta->{tenant_slug}
            or die "cannot schedule instalments without a tenant slug\n";

        # The plan stamped on the entitlement, not the line's copy.
        my ($plan) = grep { $_->{id} eq $entitlement->payment_plan_id }
            $entitlement->offer_version($raw)->payment_plans($raw)->@*;
        die "entitlement $eid has no instalments plan\n"
            unless $plan && $plan->{kind} eq 'instalments';

        # Our share -- the rate snapshotted on the charge at create, as
        # _connect_params reads it, so a retry under the keys below sends the
        # same fee even after the tenant changes plan.
        my $pct = ( $meta->{revenue_share_fraction}
            // Registry::PriceOps::RevenueShare::revenue_share_fraction_for_tenant(
                $raw, $slug ) ) * 100;

        # Bound to the account the charge was made on, where its customer and
        # card live; dies, before any Stripe call, when there is none.
        my $client = $self->stripe_client;

        # The name its product and schedule carry, stamped on the charge by the
        # first run and committed at once, so every retry under the keys below
        # sends the same params, however the offer is renamed meanwhile.
        my $description = __PACKAGE__->stamp_schedule_description( $raw, $id, $eid,
            $raw->select( 'offers', 'name',
                { id => $entitlement->offer_version($raw)->offer_id } )->array->[0] );

        # Open across the Stripe calls for the lock alone: it holds no row lock
        # until the writes at the end, so nothing waits on Stripe but another
        # run for this entitlement. Released by COMMIT, or by rollback on any death.
        my $txn = $raw->begin;
        $raw->query( 'SELECT pg_advisory_xact_lock(hashtextextended(?, 0))',
            "instalment_schedule:$eid" );
        if ( my $done = __PACKAGE__->instalment_schedule_of( $raw, $eid ) ) { return $done }

        require Registry::DAO::Entitlement;
        # A cancel (which takes this lock too) or an end that came first wins:
        # nothing is made to bill a child who has gone. A deleted one is gone.
        my $now  = Registry::DAO::Entitlement->find( $raw, { id => $eid } );
        my $gone = __PACKAGE__->schedule_cancelled( $raw, $id, $eid ) || !$now || $now->state ne 'active';

        # No start makes Stripe charge the stored dates (part two is already
        # due, or a month-end plan was not scheduled on its checkout date): so
        # nothing is made, and the studio arranges the rest by hand.
        my @today = gmtime;
        my $start = instalment_schedule_start( $plan->{cadence}, \@parts,
            sprintf( '%04d-%02d-%02d', $today[5] + 1900, $today[4] + 1, $today[3] ) );
        my $late  = !$start;

        if ( $gone || $late ) {
            # An earlier attempt may have made one at Stripe and died before
            # recording it: cancelled, so nothing bills.
            my $stopped = $self->_cancel_unrecorded( $client, $eid );
            $txn->commit;
            return undef if $gone;
            my ($child) = @{ $raw->select( 'family_members', 'child_name',
                { id => $entitlement->holder_family_member_id } )->array // [] };
            my ($session) = @{ $raw->select( 'resources', 'name', { id => $line->{resource_id} } )->array // [] };
            require Registry::DAO::Notification;
            Registry::DAO::Notification->alert_admins( $raw, 'Instalments need arranging by hand',
                sprintf( 'The instalments for %s in %s could not be scheduled at Stripe to charge on '
                       . 'their due dates (the next was due %s), so Registry has not scheduled them%s: arrange the remaining %d '
                       . 'payments with the family by hand. (Entitlement %s.)',
                    $child // 'a child', $session // 'a session', $remaining[0]{due_date},
                    ( $stopped ? ' and has cancelled the schedule an earlier attempt left at Stripe' : '' ),
                    scalar @remaining, $eid ),
                { entitlement_id => $eid } );
            return undef;
        }

        # The customer the charge was made against, and the card it saved.
        my $intent = $client->retrieve_payment_intent($stripe_payment_intent_id);
        my $customer = $intent->{customer}
            or die "payment $id has no customer to bill\n";
        my $card = $intent->{payment_method}
            or die "payment $id saved no card\n";

        # A $0 opening phase when it starts now, then the parts'
        # (instalment_schedule_params).
        my $schedule = $self->_schedule_at_stripe( $client, $customer, $pct, $eid,
            ( $start eq 'now' ) + @{ instalment_phases( \@remaining, lc $currency, $description ) } );
        $schedule ||= $client->create_subscription_schedule( {
            %{ instalment_schedule_params( {
                customer          => $customer,
                payment_method    => $card,
                revenue_share_pct => $pct,
                currency          => lc $currency,
                description       => $description,
                cadence           => $plan->{cadence},
                entitlement_id    => $eid,
                product           => $client->create_product({
                    name                       => $description,
                    'metadata[entitlement_id]' => $eid,
                    _idempotency_key           => "instalment_schedule:$eid:product",
                })->{id},
                instalments       => \@remaining,
                start             => $start,
            } ) },
            _idempotency_key => "instalment_schedule:$eid:schedule",
        } );

        # Recorded in one transaction. A crash before the COMMIT leaves a
        # schedule at Stripe with no record here; the retry's Idempotency-Key
        # gets that same schedule back, so it is recorded once.
        my $seq = 1;
        for my $part (@remaining) {
            $raw->insert( 'payments', {
                user_id            => $user_id,
                amount_cents       => $part->{amount_cents},
                currency           => $currency,
                status             => 'pending',
                instalment_seq     => ++$seq,
                instalment_count   => scalar @parts,
                due_date           => $part->{due_date},
                stripe_schedule_id => $schedule->{id},
                entitlement_id     => $eid,
                metadata           => { -json => {
                    instalment_of     => $id,
                    tenant_slug       => $slug,
                    # The account this set is charged on, so a refund of this
                    # row goes where its money went.
                    stripe_account_id => $meta->{stripe_account_id},
                    # The platform terms that priced this schedule's fee,
                    # for record_platform_fee when this row's invoice is paid.
                    platform_offer_version_id => $meta->{platform_offer_version_id},
                    platform_payment_plan_id  => $meta->{platform_payment_plan_id},
                    description   => $description,
                } },
            } );
        }

        $txn->commit;
        return $schedule->{id};
    }

    # Cancel $entitlement's instalment schedule, made from this cart charge.
    # The entitlement is appended to metadata.cancelled_schedules first, so a
    # cancel Stripe then reports is known as Registry's own; a schedule
    # already over is not asked again. Safe to repeat: the job retries it.
    # The schedule id, or undef when none was made.
    method cancel_instalment_schedule ( $db, $entitlement ) {
        my $raw = ($db isa Registry::DAO) ? $db->db : $db;
        my $eid = $entitlement->id;
        die "entitlement $eid was not made by payment $id\n"
            unless ( $entitlement->payment_id // '' ) eq $id;

        # Under schedule_instalments_for's lock, and committed before Stripe
        # is asked: a schedule run in flight finishes first and is cancelled
        # below, and one that runs later sees the record and makes nothing.
        my $txn = $raw->begin;
        $raw->query( 'SELECT pg_advisory_xact_lock(hashtextextended(?, 0))',
            "instalment_schedule:$eid" );
        $raw->query( q{
            UPDATE payments
               SET metadata = jsonb_set( COALESCE(metadata, '{}'), '{cancelled_schedules}',
                       COALESCE(metadata->'cancelled_schedules', '[]') || to_jsonb(?::text) )
             WHERE id = ?
               AND NOT COALESCE(metadata->'cancelled_schedules', '[]') @> jsonb_build_array(?::text)
        }, $eid, $id, $eid );
        my $schedule = __PACKAGE__->instalment_schedule_of( $raw, $eid );
        $txn->commit;

        # None recorded: an attempt may still have made one at Stripe before
        # it died, which the schedule job will no longer record.
        unless ($schedule) {
            $self->_cancel_unrecorded( $self->stripe_client, $eid );
            return undef;
        }

        my $client = $self->stripe_client;
        my $at     = $client->retrieve_subscription_schedule($schedule);
        my $status = $at->{status} // '';
        return $schedule if $status =~ /\A(?:canceled|completed)\z/;
        if ( $status eq 'released' ) {
            $self->_cancel_released( $raw, $client, $eid, $schedule, $at->{released_subscription} );
            return $schedule;
        }
        $client->cancel_subscription_schedule( $schedule, instalment_cancel_params( $eid, $schedule ) );
        return $schedule;
    }

    # Cancels every live schedule at Stripe naming entitlement $eid on this
    # charge's customer: ones an attempt made and died before recording. How
    # many it cancelled.
    # shortcut: reads the customer's first 100 schedules, as _schedule_at_stripe.
    method _cancel_unrecorded ( $client, $eid ) {
        my $customer = $client->retrieve_payment_intent($stripe_payment_intent_id)->{customer}
            or return 0;
        my @live = grep {
            ( $_->{metadata}{entitlement_id} // '' ) eq $eid && ( $_->{status} // '' ) =~ /\A(?:not_started|active)\z/
        } @{ $client->list_subscription_schedules( { customer => $customer, limit => 100 } )->{data} // [] };
        $client->cancel_subscription_schedule( $_->{id}, instalment_cancel_params( $eid, $_->{id} ) ) for @live;
        return scalar @live;
    }

    # A released schedule no longer bills, but the subscription it let go of
    # does, on its own: cancelled (Stripe's default: no proration, no final
    # invoice) and the admins told, since the studio's release was not ours.
    method _cancel_released ( $db, $client, $eid, $schedule, $sub ) {
        $sub = $sub->{id} if ref $sub eq 'HASH';
        return unless defined $sub && !ref $sub;
        return if ( $client->retrieve_subscription($sub)->{status} // '' ) =~ /\A(?:canceled|incomplete_expired)\z/;
        $client->cancel_subscription( $sub, { _idempotency_key => "cancel_subscription:$eid" } );
        require Registry::DAO::Notification;
        Registry::DAO::Notification->alert_admins( $db, 'A released instalment schedule was cancelled',
            "The instalment schedule $schedule for entitlement $eid had been released in Stripe, so its "
          . "subscription $sub went on billing by itself. Registry has cancelled that subscription; "
          . 'check what the family was charged since the release.',
            { entitlement_id => $eid } );
    }

    # The cancel request for entitlement $eid's schedule. No proration and no
    # final invoice: what a family is owed back is the refund policy's call
    # on what it paid, not a credit Stripe works out.
    sub instalment_cancel_params ( $eid, $schedule ) {
        return { prorate => 'false', invoice_now => 'false', _idempotency_key => "cancel_schedule:$eid:$schedule" };
    }

    # Entitlement $eid's schedule name as payment $payment_id first stamped
    # it, stamping $name when none is.
    sub stamp_schedule_description ( $class, $db, $payment_id, $eid, $name ) {
        return $db->query( q{
            UPDATE payments
               SET metadata = COALESCE(metadata, '{}') || jsonb_build_object( 'schedule_descriptions',
                       COALESCE(metadata->'schedule_descriptions', '{}')
                       || jsonb_build_object( ?::text, COALESCE(metadata->'schedule_descriptions'->>?::text, ?::text) ) )
             WHERE id = ?
         RETURNING metadata->'schedule_descriptions'->>?::text
        }, $eid, $eid, $name, $payment_id, $eid )->array->[0];
    }

    # Has payment $payment_id recorded entitlement $eid's schedule as cancelled?
    sub schedule_cancelled ( $class, $db, $payment_id, $eid ) {
        return $db->query( q{
            SELECT 1 FROM payments
             WHERE id = ? AND COALESCE(metadata->'cancelled_schedules', '[]') @> jsonb_build_array(?::text)
        }, $payment_id, $eid )->rows;
    }

    # The Stripe schedule billing entitlement $eid's instalments, or undef.
    sub instalment_schedule_of ( $class, $db, $eid ) {
        my $row = $db->query( q{
            SELECT stripe_schedule_id FROM payments
             WHERE entitlement_id = ? AND stripe_schedule_id IS NOT NULL LIMIT 1
        }, $eid )->array;
        return $row && $row->[0];
    }

    # This cart charge's line for $entitlement: its child in the session it
    # holds (a child is in a session at most once per cart).
    method _line_for ( $db, $entitlement ) {
        my %held = map { $_ => 1 } $entitlement->unit_resource_ids($db);
        my $child = $entitlement->holder_family_member_id // return undef;
        my ($line) = grep { ( $_->{family_member_id} // '' ) eq $child && $held{ $_->{resource_id} // '' } }
            @{ ( $metadata // {} )->{lines} // [] };
        return $line;
    }

    # A live schedule at Stripe made for entitlement $eid, or undef. Each
    # carries metadata[entitlement_id] (schedule_instalments_for) -- but it is
    # on the seller's own account, where the seller can write that too, so it
    # is adopted only if it takes our fee in as many phases as we would send.
    # shortcut: phase amounts are not compared, as a listed phase's price is an
    # id; expand data.phases.items.price if a seller ever games the count.
    # shortcut: reads the customer's first 100 schedules; page through them
    # if one customer ever holds more.
    method _schedule_at_stripe ($client, $customer, $pct, $eid, $phase_count) {
        my $listed = $client->list_subscription_schedules(
            { customer => $customer, limit => 100 } );
        my $ours = sprintf '%.2f', $pct;
        for my $s ( @{ $listed->{data} // [] } ) {
            next unless ( $s->{metadata}{entitlement_id} // '' ) eq $eid
                && ( $s->{status} // '' ) !~ /\A(?:canceled|released)\z/;
            return $s
                if sprintf( '%.2f', $s->{default_settings}{application_fee_percent} // 0 ) eq $ours
                && @{ $s->{phases} // [] } == $phase_count;
            warn "not adopting Stripe schedule "
                . ( ( $s->{id} // "" ) =~ s/([^\x20-\x7e])/sprintf '\\x{%x}', ord $1/ger )
                . " for entitlement $eid: its fee or phases are not ours\n";
        }
        return undef;
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

    # --- Settling Stripe's reports (Controller::Webhooks) ------------------
    # Each status write carries its legality in the WHERE, as the writers
    # below do: a completed or refunded row is history to every invoice.

    # The instalment set billed by $schedule, locked in seq order until the
    # caller's transaction ends: one invoice at a time per schedule.
    sub lock_instalment_set ( $class, $db, $schedule ) {
        $db->query( q{
            SELECT 1 FROM payments WHERE stripe_schedule_id = ?
             ORDER BY instalment_seq FOR UPDATE
        }, $schedule );
    }

    # { id, status } of the instalment of $schedule that invoice $invoice_id
    # already bound, locked; else undef.
    sub instalment_for_invoice ( $class, $db, $schedule, $invoice_id ) {
        return $db->query( q{
            SELECT id, status FROM payments
             WHERE stripe_schedule_id = ?
               AND metadata->>'stripe_invoice_id' = ?
             FOR UPDATE
        }, $schedule, $invoice_id )->hash;
    }

    # { id, status } of the earliest pending instalment of $schedule no
    # invoice has bound, locked; else undef.
    sub next_unbound_instalment ( $class, $db, $schedule ) {
        return $db->query( q{
            SELECT id, status FROM payments
             WHERE stripe_schedule_id = ?
               AND status = 'pending'
               AND metadata->>'stripe_invoice_id' IS NULL
             ORDER BY instalment_seq
             LIMIT 1
             FOR UPDATE
        }, $schedule )->hash;
    }

    # Instalment $id failed for $why, where that move is legal: its invoice
    # was closed, so Stripe will not charge it.
    sub close_instalment ( $class, $db, $id, $why ) {
        $db->query( q{UPDATE payments SET status = 'failed', error_message = ? WHERE id = ? AND status = ANY(?)},
            $why, $id, $class->_legal_predecessors('failed') );
    }

    # Instalment $id completed by $intent on invoice $invoice_id, where that
    # move is legal. The number of rows changed, 0 or 1.
    sub complete_instalment ( $class, $db, $id, $intent, $invoice_id ) {
        return $db->query( q{
            UPDATE payments
               SET status = 'completed', completed_at = now(),
                   stripe_payment_intent_id = ?, error_message = NULL,
                   metadata = COALESCE(metadata, '{}')
                       || jsonb_build_object('stripe_invoice_id', ?::text)
             WHERE id = ? AND status = ANY(?)
        }, $intent, $invoice_id, $id, $class->_legal_predecessors('completed') )->rows;
    }

    # Binds instalment $id to invoice $invoice_id, its status untouched.
    sub bind_instalment_invoice ( $class, $db, $id, $invoice_id ) {
        $db->query( q{
            UPDATE payments
               SET metadata = COALESCE(metadata, '{}')
                   || jsonb_build_object('stripe_invoice_id', ?::text)
             WHERE id = ?
        }, $invoice_id, $id );
    }

    # Instalment $id failed for $why on invoice $invoice_id, charged as
    # $intent when given, where that move is legal.
    sub fail_instalment ( $class, $db, $id, $why, $intent, $invoice_id ) {
        $db->query( q{
            UPDATE payments
               SET status = 'failed', error_message = ?,
                   stripe_payment_intent_id = COALESCE(?, stripe_payment_intent_id),
                   metadata = COALESCE(metadata, '{}')
                       || jsonb_build_object('stripe_invoice_id', ?::text)
             WHERE id = ? AND status = ANY(?)
        }, $why, $intent, $invoice_id, $id, $class->_legal_predecessors('failed') );
    }

    # Is $entitlement_id (compared as text: it need not be a uuid) an
    # instalments entitlement whose cart charge is paid, still awaiting its
    # schedule?
    sub instalment_awaiting_schedule ( $class, $db, $entitlement_id ) {
        return $db->query( q{
            SELECT 1 FROM entitlements e JOIN payments p ON p.id = e.payment_id
             WHERE e.id::text = ? AND e.plan_kind = 'instalments' AND p.status = 'completed'
               AND NOT EXISTS ( SELECT 1 FROM payments o
                                 WHERE o.entitlement_id = e.id AND o.stripe_schedule_id IS NOT NULL )
        }, $entitlement_id )->rows;
    }

    # The schedules whose instalment set still has a row owed.
    sub schedules_with_owed_instalments ( $class, $db ) {
        return $db->query( q{
            SELECT DISTINCT stripe_schedule_id FROM payments
             WHERE stripe_schedule_id IS NOT NULL AND status IN ('pending', 'failed')
        } )->arrays->flatten;
    }

    # How many instalments of $schedule invoice $invoice_id has bound.
    sub instalment_invoice_bound ( $class, $db, $schedule, $invoice_id ) {
        return $db->query( q{
            SELECT 1 FROM payments
             WHERE stripe_schedule_id = ? AND metadata->>'stripe_invoice_id' = ?
        }, $schedule, $invoice_id )->rows;
    }

    # How many payments were made by one of the intents in @$intents.
    sub count_with_intents ( $class, $db, $intents ) {
        return $db->select( 'payments', 'id', { stripe_payment_intent_id => { -in => $intents } } )->rows;
    }

    # How many payments in schema $slug hold refund $refund_id as pending.
    sub count_holding_pending_refund_in ( $class, $db, $slug, $refund_id ) {
        return $db->query(
            sprintf( q{SELECT 1 FROM %s.payments WHERE metadata->'pending_refunds'->?::text IS NOT NULL},
                $db->dbh->quote_identifier($slug) ), $refund_id )->rows;
    }

    # { id } of the payment holding refund $refund_id as pending, or undef.
    sub holding_pending_refund ( $class, $db, $refund_id ) {
        return $db->query(
            q{SELECT id FROM payments WHERE metadata->'pending_refunds'->?::text IS NOT NULL},
            $refund_id )->hash;
    }

    # Records that $amount of the platform fee on intent $intent has gone
    # back; the highest amount reported wins. The number of rows changed.
    sub record_platform_fee_refunded ( $class, $db, $intent, $amount ) {
        return $db->query(
            q{UPDATE payments
                 SET platform_fee_refunded_cents =
                     GREATEST(COALESCE(platform_fee_refunded_cents, 0), ?)
               WHERE stripe_payment_intent_id = ?},
            $amount, $intent )->rows;
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

    # The platform's share of a direct charge. The charge is made on the
    # seller's own account (stripe_client is bound to it), so the tenant is the
    # merchant of record without transfer_data or on_behalf_of; all that is
    # left to send is the application fee. Read from the payment's own
    # metadata -- the account snapshotted by create -- so every intent for this
    # payment, retries included, routes the same way. tenants has no jsonb
    # columns; plain ->hash is sufficient.
    sub _connect_params ($db, $metadata, $amount_cents) {
        $db = $db->db if $db isa Registry::DAO;
        my $meta = ref $metadata eq 'HASH' ? $metadata : {};
        return () unless $meta->{stripe_account_id};

        # The fraction create snapshotted; the tenant's live terms only for a
        # row made before the snapshot existed. $db is already a Mojo::Pg handle here
        # (coerced at the top of this sub).
        my $fraction = $meta->{revenue_share_fraction}
            // Registry::PriceOps::RevenueShare::revenue_share_fraction_for_tenant(
                $db, $meta->{tenant_slug} );
        my $fee = application_fee_cents($amount_cents, $fraction);

        # Stripe's rule: a zero application fee is omitted, never sent as 0.
        return $fee ? ( application_fee_amount => $fee ) : ();
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

        # The seller's Stripe account, resolved once from the seller row and
        # kept with the payment: every intent, retry, retrieve and cancel for
        # this payment goes to the account it was first charged on, even if the
        # tenant's account changes later. Server-owned, so a caller's value is
        # never trusted. The platform tenant sells like any other seller.
        #
        # The revenue share is fixed here too, at quote time (ruling 7c): every
        # intent for this payment shares one Idempotency-Key, and Stripe refuses
        # a retry under it that carries a different application_fee_amount.
        # So are the platform offer version and payment plan that rate came
        # from, recorded with the fee. A tenant with no platform entitlement in
        # effect dies here, before any row is written or Stripe is called.
        delete $data->{metadata}->@{qw( stripe_account_id revenue_share_fraction
                                        platform_offer_version_id platform_payment_plan_id )};
        if ( my $slug = $data->{metadata}{tenant_slug} ) {
            my $row = $raw_db->query(
                'SELECT stripe_connect_account_id FROM registry.tenants WHERE slug = ?',
                $slug )->hash;
            if ( $row && $row->{stripe_connect_account_id} ) {
                $data->{metadata}{stripe_account_id} = $row->{stripe_connect_account_id};
                my $terms = Registry::PriceOps::PlatformTerms::platform_terms_for_tenant(
                    $raw_db, $slug );
                $data->{metadata}->@{qw( revenue_share_fraction platform_offer_version_id
                                         platform_payment_plan_id )} = $terms->@{qw( fraction id plan_id )};
            }
        }
        $data->{metadata} = { -json => $data->{metadata} };

        return $class->SUPER::create($db, $data);
    }
    
    # The env-reading and the live-key guard live on the service now, so the
    # Connect-onboarding controller enforces the same rule rather than growing a
    # second copy of it. This keeps the per-payment cache. The client is bound
    # to the seller account create snapshotted, so every call it makes for this
    # payment carries that Stripe-Account.
    method stripe_client {
        return $_stripe_client if $_stripe_client;

        # No fallback to an unbound client: that would charge the platform's
        # own account for a sale that belongs to the seller.
        my $acct = ref $metadata eq 'HASH' ? $metadata->{stripe_account_id} : undef;
        die "payment $id has no seller Stripe account to charge on\n" unless $acct;

        # Handle SSL requirement gracefully in test environments
        eval { $_stripe_client = Registry::Service::Stripe->from_env->for_account($acct) };

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

    # The email and name are snapshotted on first use: a retry under the same
    # key must send the same body, or Stripe answers idempotency_error when the
    # parent edited their profile in between.
    method _customer_params ($raw) {
        my $details = $metadata->{stripe_customer_details};
        unless ( ref $details eq 'HASH' ) {
            require Registry::DAO::User;
            my $user = Registry::DAO::User->find( $raw, { id => $user_id } );
            $details = {
                ( $user && $user->email ? ( email => $user->email ) : () ),
                ( $user && $user->name  ? ( name  => $user->name )  : () ),
            };
            $raw->query( q{
                UPDATE payments
                   SET metadata = COALESCE(metadata, '{}'::jsonb)
                                  || jsonb_build_object('stripe_customer_details', ?::jsonb)
                 WHERE id = ?
            }, { json => $details }, $id );
            $metadata->{stripe_customer_details} = $details;
        }

        return {
            %$details,
            'metadata[registry_user_id]' => $user_id // '',
            # One customer per payment: a create whose response was lost is
            # retried under this key and Stripe returns the customer it made.
            _idempotency_key => "customer-create:$id",
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
        my $stored_intent =
            defined $stripe_payment_intent_id && $intent_id eq $stripe_payment_intent_id;
        my $owned = $stored_intent
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

        # A stamp may learn the row is settled, as above, but only the intent
        # Registry created may move it: the seller owns the account the intent
        # is retrieved from, and can mint one stamped with our payment_id.
        unless ($stored_intent) {
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
            $self->record_platform_fee( $db, $intent );

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
    
    # Write down the application fee and the platform terms it was charged under.
    # All three settlement paths -- process_payment (via _apply_intent), the
    # payment_intent webhook, and the instalment invoice handler -- call this, so
    # the missing-fee rule lives here once. $intent is whatever Stripe object
    # reported the fee: the payment intent, or the invoice for instalments 2..N.
    #
    # Best effort: a failure here must not undo a captured charge. The payment is
    # settled and the enrolment is the point; an unrecorded fee leaves a NULL,
    # which the revenue view reports as a gap rather than silently summing as
    # zero.
    #
    # The stamp is the offer version and plan create snapshotted beside the
    # rate, so it names the terms that priced the fee even when the tenant
    # moves to another version between quote and settle (up to a day). The
    # tenant's live terms only for a row create did not snapshot -- one with
    # no seller account.
    method record_platform_fee ( $db, $intent ) {
        $db = $db->db if $db isa Registry::DAO;

        # Stripe omits a zero application fee rather than sending 0, so a
        # charge on a seller's account that reports none took nothing. A row
        # with no seller account sent no Connect params: its fee stays NULL.
        my $connected = ref $metadata eq 'HASH' && $metadata->{stripe_account_id};
        my $fee = $intent->{application_fee_amount} // ( $connected ? 0 : undef );
        return unless defined $fee && !ref $fee;

        my $slug = ( ref $metadata eq 'HASH' ? $metadata->{tenant_slug} : undef );

        my %stamp;
        if ( $connected ) {
            %stamp = ( version => $metadata->{platform_offer_version_id},
                       plan    => $metadata->{platform_payment_plan_id} );
        }
        elsif ( defined $slug && !ref $slug && length $slug ) {
            # Best-effort like the write below: unreadable terms must not fail settlement.
            eval {
                my $terms = Registry::PriceOps::PlatformTerms::platform_terms_for_tenant( $db, $slug );
                %stamp = ( version => $terms->{id}, plan => $terms->{plan_id} );
                1;
            } or do {
                my $err = $@ || 'unknown error';
                $err =~ s/\s+/ /g;
                warn "could not resolve platform terms for payment $id: $err\n";
            };
        }

        eval {
            $db->update( 'payments',
                { platform_fee_cents        => $fee,
                  platform_offer_version_id => $stamp{version},
                  platform_payment_plan_id  => $stamp{plan} },
                { id => $id } );
            $platform_fee_cents        = $fee;
            $platform_offer_version_id = $stamp{version};
            $platform_payment_plan_id  = $stamp{plan};
            1;
        } or do {
            my $err = $@ || 'unknown error';
            $err =~ s/\s+/ /g;
            warn "could not record platform fee for payment $id: $err\n";
        };

        return;
    }

    # The platform terms this payment's fee was taken under: the offer version
    # and payment plan stamped on it, superseded or not. Refunds resolve
    # backwards from these, never from the tenant's current terms. Dies when
    # the payment carries no stamp.
    method stamped_platform_terms ($db) {
        my $meta    = ref $metadata eq 'HASH' ? $metadata : {};
        my $version = $platform_offer_version_id // $meta->{platform_offer_version_id};
        my $plan    = $platform_payment_plan_id  // $meta->{platform_payment_plan_id};
        die "payment $id carries no platform terms stamp\n" unless $version && $plan;
        return Registry::PriceOps::PlatformTerms::platform_version_terms( $db, $version, $plan );
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
            : [],
            # True here and nowhere else on this path: these children have no
            # seat, so no money attached to them. The demotion path deliberately
            # omits this, because that parent was charged and is being refunded.
            nothing_charged => 1 );

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



    # refund.updated for a refund _apply_refund_result held as pending. A
    # terminal answer is recorded as _apply_refund_result records any other,
    # from what the refund was sent as; a succeeded one then discharges its
    # capacity increment or marks its dropped seat processed. Returns the
    # status recorded, or nothing when the refund is not held here or is
    # still in flight. Once: the hold is released by the recording.
    method settle_pending_refund ($db, $refund) {
        $db = $db->db if $db isa Registry::DAO;
        return if __CLASS__->refund_is_pending($refund);

        my $row = $db->query( <<'SQL', $refund->{id}, $id )->expand->hash;
            SELECT metadata->'pending_refunds'->?::text AS held
              FROM payments WHERE id = ? FOR UPDATE
SQL
        my $held = $row && $row->{held} or return;
        my $key  = $held->{key} // '';
        my ($seq)        = $key =~ /\Arefund:capacity:\Q$id\E:(\d+)\z/;
        my ($enrollment) = $key =~ /\Arefund:drop:\Q$id\E:(.+)\z/;

        $self->_apply_refund_result( $db, $refund, $held->{cents}, $held->{reason},
            defined $seq ? 1 : 0, $held->{key} );

        if ( ( $refund->{status} // '' ) eq 'succeeded' ) {
            $self->settle_refund_increment( $db, $seq, $refund ) if defined $seq;
            $db->update( 'enrollments', { refund_status => 'processed' },
                { id => $enrollment, payment_id => $id } ) if defined $enrollment;
        }
        else {
            # So a replay of this refund's first "pending" answer is not held again.
            $db->query( q{UPDATE payments SET metadata = metadata || jsonb_build_object('failed_refunds',
                    COALESCE(metadata->'failed_refunds', '{}'::jsonb) || jsonb_build_object(?::text, ?::text))
                 WHERE id = ?}, $refund->{id}, $refund->{status} // 'unknown', $id );
            $self->record_refund_failure( $db, "Stripe refund $refund->{id} on payment $id is "
                . ( $refund->{status} // 'unknown' )
                . ( defined $refund->{failure_reason} ? " ($refund->{failure_reason})" : '' ) );
        }
        return $refund->{status};
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
            # -json rather than encode_json: the latter hands UTF-8 bytes to a
            # jsonb column and Postgres encodes them again (#485). Latent here
            # today -- only child_id and session_id ride in this metadata, and
            # the child's NAME goes in `description`, which is a text column --
            # but that is a property of today's callers, not of the column.
            metadata => { -json => $args->{metadata} // {} },
        };
        
        $db->insert('payment_items', $item);
    }
    
    method line_items ($db) {
        $db = $db->db if $db isa Registry::DAO;
        # ->expand, so Mojo::Pg decodes the jsonb column itself -- which is what
        # DAO::Object::find does and what every other reader here relies on.
        # This hand-decoded with decode_json instead, which decodes BYTES, while
        # Postgres returns characters: it died with "Input is not UTF-8 encoded"
        # on anything non-ASCII the moment the write side stopped storing
        # double-encoded bytes (#485).
        return $db->select( 'payment_items', '*',
            { payment_id => $self->id } )->expand->hashes;
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

        # The intent it replaces is kept: a decline's cancel is best-effort, and
        # if it failed a stale tab can still pay the old one. The webhook
        # refunds a superseded intent that succeeds; it settles nothing.
        # SET reads the row as it was, so the old id is the one appended. The
        # new id leaves the list: an A-B-A resubmit re-stores a superseded one.
        # The newest 20 are kept, as each decline retry adds one.
        # shortcut: an older intent paid from a stale tab is only warned about
        # by the webhook, not refunded; raise the cap if that warning shows up.
        my $moved = $db->query( <<'SQL', $intent_id, $intent_id, $intent_id, $id, __CLASS__->_settled_statuses )->rows;
            UPDATE payments
               SET metadata = CASE
                       WHEN stripe_payment_intent_id IS NULL
                         OR stripe_payment_intent_id = ? THEN metadata
                       ELSE jsonb_set( COALESCE(metadata, '{}'::jsonb), '{superseded_intent_ids}',
                                jsonb_path_query_array(
                                    ( COALESCE(metadata->'superseded_intent_ids', '[]'::jsonb)
                                      || to_jsonb(stripe_payment_intent_id) ) - ?::text,
                                    '$[last - 19 to last]' ) )
                   END,
                   stripe_payment_intent_id = ?
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

    # partially_refunded, so a second drop from one cart can be refunded (005
    # 8a); refund_async's past-captured guard caps it at what remains.
    sub _refundable_status ($class, $status) {
        return ( $status // '' )
            =~ /\A (?: completed | refund_pending | partially_refunded ) \z/x ? 1 : 0;
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
    method _apply_refund_result ($db, $refund, $refund_cents, $reason, $is_increment = 0, $key = undef) {
        $db = $db->db if $db isa Registry::DAO;

        # Only a succeeded refund has moved money. A pending one may still fail
        # and a failed or canceled one never will, so none of them moves status
        # or refunded_cents, or is remembered as counted.
        # A pending one is held under pending_refunds with what it was sent
        # as, so settle_pending_refund can count it when refund.updated says
        # it succeeded; any other answer releases the hold.
        my $pending   = ( $refund->{status} // '' ) eq 'succeeded' ? 0 : 1;
        my $hold      = $is_increment || $pending ? 1 : 0;
        my $in_flight = __CLASS__->refund_is_pending($refund);

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
        #
        # A counted refund is remembered by its Stripe id (with the key it went
        # out under), and the whole write is skipped for an id already there: a
        # retry under the same Idempotency-Key gets the same refund back, and
        # adding it again told the ledger more went back than the bank sent.
        #
        # A refund that has moved money retires record_refund_failure's stamp,
        # which the runbook reads first; a pending one may still fail, so not yet.
        # shortcut: one failure slot per payment, so a sibling drop's success on the same cart clears it too (that drop stays findable by its enrollment's refund_status); key the record by idempotency key if that ever misleads an operator.
        $db->query( <<'SQL', $pending, $refund->{id}, encode_json({
            UPDATE payments
               SET metadata = ( CASE WHEN ?::boolean THEN COALESCE(metadata, '{}'::jsonb)
                                     ELSE COALESCE(metadata, '{}'::jsonb) - 'refund_last_failure' END
                                #- ARRAY['pending_refunds', ?::text] )
                   || ?::jsonb
                   || CASE WHEN ?::boolean THEN '{}'::jsonb
                      ELSE jsonb_build_object('recorded_refunds',
                          COALESCE(metadata->'recorded_refunds', '{}'::jsonb)
                          || jsonb_build_object(?::text, ?::text)) END
                   || CASE WHEN ?::boolean THEN jsonb_build_object('pending_refunds',
                          COALESCE(metadata->'pending_refunds', '{}'::jsonb)
                          || jsonb_build_object(?::text, ?::jsonb))
                      ELSE '{}'::jsonb END,
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
               AND metadata->'recorded_refunds'->?::text IS NULL
SQL
            refund_id           => $refund->{id},
            refund_amount_cents => $refund_cents,
            refund_reason       => $reason,
            refund_status       => $refund->{status},
        }), $hold, $refund->{id}, $key,
            $in_flight, $refund->{id},
            encode_json({ key => $key, cents => $refund_cents, reason => $reason }),
            $hold, $refund_cents, $hold, $refund_cents,
            $id, $refund->{id} );

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

    # Stripe has not moved the money yet and may still fail: settled later by
    # refund.updated, and until then neither counted nor treated as done.
    sub refund_is_pending ( $class, $refund ) {
        return ( ( ref $refund eq 'HASH' ? $refund->{status} : undef ) // '' )
            =~ /\A(?:pending|requires_action)\z/ ? 1 : 0;
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

        # A retry (a drop whose step died after Stripe paid) of a refund already
        # recorded under this key gets that refund back. The guards below would
        # refuse it, because the payment already reflects it. Only a succeeded
        # refund is ever recorded there, so 'succeeded' is what was recorded.
        # refund_last_failure is left alone: only a non-increment (drop) refund
        # is recorded, and recording it cleared the slot, so a failure here now
        # is a sibling's on the same cart -- still owed, and this moved no money.
        if ( my $key = $args->{idempotency_key} ) {
            my $done = $db->query( q{
                SELECT r.key AS id, 'succeeded' AS status
                  FROM payments, jsonb_each_text(metadata->'recorded_refunds') r
                 WHERE payments.id = ? AND r.value = ?}, $id, $key )->hash;
            return Mojo::Promise->resolve($done) if $done;
        }

        # Still pending under this key: resending replays "pending" inside
        # Stripe's 24h key window, and past it creates a second real refund.
        if ( my $key = $args->{idempotency_key} ) {
            my $held = $db->query( q{
                SELECT p.key AS id, 'pending' AS status
                  FROM payments, jsonb_each(metadata->'pending_refunds') p
                 WHERE payments.id = ? AND p.value->>'key' = ?}, $id, $key )->hash;
            return Mojo::Promise->resolve($held) if $held;
        }

        # Marked, because what an operator needs to know first is whether any
        # money can have moved, and for these it certainly cannot: the request
        # is never dispatched. Classifying on a marker rather than on wording --
        # Stripe's or ours -- keeps that answer from turning on a message
        # somebody reworded.
        die REFUND_NOT_SENT . ": Cannot refund a payment with status '$status'"
            unless __CLASS__->_refundable_status($status);
        die REFUND_NOT_SENT . ": No Stripe payment intent ID"
            unless $stripe_payment_intent_id;

        # Read fresh: the object may predate a settled increment.
        my $fresh = $db->query(
            'SELECT refunded_cents, refund_owed_cents FROM payments WHERE id = ?', $id
        )->hash // {};
        my $refunded = $fresh->{refunded_cents} // 0;
        # With no amount, return what is left, not the whole charge again (005 8a).
        my $refund_cents = $args->{amount_cents} // $amount_cents - $refunded;
        my $reason = $args->{reason} // 'requested_by_customer';

        # Stripe refuses these too, after the request, where it reads as unknown.
        die REFUND_NOT_SENT . ": Refund of $refund_cents cents on payment $id is not positive\n"
            unless $refund_cents > 0;

        # Stripe would refuse it too, but only after the request went out.
        # Capacity debt is money already owed back on this charge, so it counts
        # against what is left -- except for an increment, which IS that debt.
        my $owed = $args->{increment} ? 0 : $fresh->{refund_owed_cents} // 0;
        die REFUND_NOT_SENT . ": Refund of $refund_cents cents would take payment $id "
          . "past its $amount_cents captured cents ($refunded already refunded, "
          . "$owed owed)\n"
            if $refunded + $owed + $refund_cents > $amount_cents;

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

        # stripe_client refuses too, but unmarked; this says no money moved.
        die REFUND_NOT_SENT . ": payment $id has no seller Stripe account\n"
            unless ref $metadata eq 'HASH' && $metadata->{stripe_account_id};

        return $self->stripe_client->create_refund_async({
            payment_intent => $stripe_payment_intent_id,
            amount         => $refund_cents,
            reason         => $reason,
            $args->{idempotency_key}
                ? ( _idempotency_key => $args->{idempotency_key} ) : (),
        })->then(sub ($refund) {
            # A key replayed inside Stripe's window answers with the refund's
            # first response, "pending", for a refund refund.updated already failed.
            my $failed = $db->query( q{SELECT metadata->'failed_refunds'->>?::text AS status
                FROM payments WHERE id = ?}, $refund->{id}, $id )->hash->{status};
            die "Stripe refund $refund->{id} on payment $id is $failed\n" if $failed;
            # Told, not inferred. This used to read the presence of an
            # idempotency key as "this is a capacity increment", because at the
            # time only increments carried one. They are two independent
            # decisions -- whether settle_refund_increment owns the status, and
            # whether a retry is safe -- and a direct refund that wants
            # idempotency (a dropped seat, #286) was silently accounted as an
            # increment, so refunded_cents never moved and the ledger denied a
            # refund the bank had made.
            $self->_apply_refund_result( $db, $refund, $refund_cents, $reason,
                $args->{increment} ? 1 : 0, $args->{idempotency_key} );
            # Recorded as such above; the caller's failure branch keeps it owed.
            die "Stripe refund $refund->{id} on payment $id is $refund->{status}\n"
                if ( $refund->{status} // '' ) =~ /\A(?:failed|canceled)\z/;
            return $refund;
        })->catch(sub ($error) {
            die "Refund failed: $error";
        });
    }

    # Returning the platform's fee: the exception to keeping it on a refund
    # (005), applied by the platform tenant's admin. The charge is the seller's,
    # so its fee id is read through the seller-bound client; the fee is the
    # platform's, so it is read and refunded on an unbound one. A fee refund
    # sent is recorded later, from application_fee.refunded; a fee Stripe shows
    # already returned in full is recorded here, and nothing is sent.
    method refund_platform_fee_async ($db, $args = {}) {
        $db = $db->db if $db isa Registry::DAO;
        die REFUND_NOT_SENT . ": No Stripe payment intent ID\n"
            unless $stripe_payment_intent_id;
        die REFUND_NOT_SENT . ": payment $id has no seller Stripe account\n"
            unless ref $metadata eq 'HASH' && $metadata->{stripe_account_id};

        # The exception is a term of the platform offer version stamped on the
        # payment, read backwards: a version whose refund policy has none, or
        # a payment with no stamp, keeps its fee.
        my $policy = eval { $self->stamped_platform_terms($db)->{refund_policy}{kind} } // 'none';
        die REFUND_NOT_SENT . ": payment $id was charged under a refund policy ($policy) with no "
          . "admin exception to return the platform fee\n"
            unless $policy eq 'keep_fee_with_admin_exception';

        my $asked = $args->{amount_cents};
        die REFUND_NOT_SENT . ": Fee refund of '$asked' cents on payment $id is not a positive whole number\n"
            if defined $asked && !( $asked =~ /\A[0-9]+\z/ && $asked > 0 );

        my $platform = Registry::Service::Stripe->from_env;
        my $charge_id;

        return $self->stripe_client->retrieve_payment_intent_async(
            $stripe_payment_intent_id, { 'expand[]' => 'latest_charge' }
        )->then(sub ($intent) {
            my $charge = $intent->{latest_charge};
            my $fee_id = ref $charge eq 'HASH' ? $charge->{application_fee} : undef;
            die REFUND_NOT_SENT . ": the charge for payment $id took no application fee\n"
                unless $fee_id;
            $charge_id = $charge->{id};
            return $platform->retrieve_application_fee_async($fee_id);
        })->then(sub ($fee) {
            my $plan = $self->platform_fee_refund_plan( $fee, $charge_id, $asked );
            if ( defined $plan->{returned} ) {
                # As application_fee.refunded records it: the highest figure wins.
                $db->query( q{UPDATE payments
                     SET platform_fee_refunded_cents = GREATEST(COALESCE(platform_fee_refunded_cents, 0), ?)
                   WHERE id = ?}, $plan->{returned}, $id );
                return { already_returned_cents => $plan->{returned} };
            }
            return $platform->create_application_fee_refund_async( $fee->{id}, {
                amount => $plan->{send},
                $args->{idempotency_key}
                    ? ( _idempotency_key => $args->{idempotency_key} ) : (),
            } );
        });
    }

    # What returning $asked cents (undef: all that is left) of Stripe's $fee,
    # read from charge $charge_id, comes to: { send => cents }, or
    # { returned => cents } when none of it is left -- an earlier press, or a
    # return outside the workflow, already took it back. A request above what
    # is left is capped there; one above the whole fee, or a fee that is not
    # this payment's, is refused.
    method platform_fee_refund_plan ( $fee, $charge_id, $asked = undef ) {
        my $account = ref $metadata eq 'HASH' ? $metadata->{stripe_account_id} // '' : '';
        die REFUND_NOT_SENT . ": fee $fee->{id} is on charge '" . ( $fee->{charge} // '' )
          . "', not payment $id's charge '" . ( $charge_id // '' ) . "'\n"
            unless defined $charge_id && ( $fee->{charge} // '' ) eq $charge_id;
        die REFUND_NOT_SENT . ": fee $fee->{id} came from account '" . ( $fee->{account} // '' )
          . "', not payment $id's seller account '$account'\n"
            unless length $account && ( $fee->{account} // '' ) eq $account;
        die REFUND_NOT_SENT . ": Fee refund of $asked cents on payment $id is more than the "
          . "$fee->{amount}-cent fee\n"
            if defined $asked && $asked > $fee->{amount};

        my $left = $fee->{amount} - $fee->{amount_refunded};
        return { returned => $fee->{amount_refunded} } unless $left > 0;
        return { send => defined $asked && $asked < $left ? $asked : $left };
    }
}

1;