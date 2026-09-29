use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::PricingPlan :isa(Registry::DAO::Object) {
    use Carp qw( croak );
    use Mojo::JSON qw( decode_json encode_json );
    use List::Util qw( min );
    use Scalar::Util qw( blessed );
    
    field $id :param :reader;
    field $session_id :param :reader = undef;
    field $plan_scope :param :reader = 'customer';
    field $plan_name :param :reader;
    field $plan_type :param :reader = 'standard';
    field $pricing_model_type :param :reader = 'fixed';
    field $amount_cents :param :reader = 0;
    field $currency :param :reader = 'USD';
    field $requirements :param :reader = {};
    field $pricing_configuration :param :reader = {};
    field $metadata :param :reader = {};
    # Versioning. `id` is this VERSION's identity and therefore what a charge, a
    # tenant link or a schedule points at. `plan_family_id` is the plan itself,
    # stable across its versions. `superseded_at` NULL means current, and the
    # database permits exactly one current version per family.
    field $plan_family_id :param :reader = undef;
    field $version :param :reader = 1;
    field $superseded_at :param :reader = undef;
    field $created_at :param :reader;
    field $updated_at :param :reader;
    
    sub table { 'pricing_plans' }
    
    ADJUST {
        # Decode JSON fields if they're strings
        for my $field ($requirements, $pricing_configuration, $metadata) {
            if (defined $field && !ref $field) {
                try {
                    $field = decode_json($field);
                }
                catch ($e) {
                    croak "Failed to decode JSON: $e";
                }
            }
        }
        
    }
    
    sub create ($class, $db, $data) {
        # Encode JSON fields
        for my $field (qw(requirements pricing_configuration metadata)) {
            if (exists $data->{$field} && ref $data->{$field} eq 'HASH') {
                $data->{$field} = { -json => $data->{$field} };
            }
        }

        # Set defaults
        $data->{plan_type} //= 'standard';
        $data->{pricing_model_type} //= 'fixed';
        $data->{plan_scope} //= 'customer';
        $data->{currency} //= 'USD';
        $data->{requirements} //= { -json => {} };
        $data->{pricing_configuration} //= { -json => {} };
        $data->{metadata} //= { -json => {} };

        # Use unqualified table name so the connection's search_path determines
        # the schema.  This allows both the registry schema and tenant schemas
        # to store pricing plans in their own pricing_plans table.
        my $table = 'pricing_plans';

        $db = $db->db if $db isa Registry::DAO;

        # Add proper error handling and connection management
        try {
            my %result = $db->insert($table, $data, { returning => '*' })->expand->hash->%*;

            # A first version is its own family. Stamped after the insert because
            # the value is the row's own generated id, which no DEFAULT can
            # reference. This is the one write that touches an existing plan row
            # and it completes the row's identity rather than changing its terms
            # -- every later change appends a version instead (see revise).
            unless ( defined $result{plan_family_id} ) {
                $db->query(
                    'UPDATE pricing_plans SET plan_family_id = id
                      WHERE id = ? AND plan_family_id IS NULL', $result{id} );
                $result{plan_family_id} = $result{id};
            }

            return $class->new(%result);
        }
        catch ($e) {
            croak "Failed to create pricing plan: $e";
        }
    }

    # Append a new version of this plan, carrying %$changes over the current
    # terms, and retire the version being replaced.
    #
    # This is the only way to change a plan. Editing in place re-prices everybody
    # already on it, retroactively, and destroys the only record of what the old
    # price was -- and because payment_items records the version a charge used,
    # an in-place edit would also rewrite history that other rows point at.
    #
    # Returns the new version. Both writes happen in one transaction: a family
    # with no current version is as broken as one with two, and the database
    # refuses the second.
    method revise ($db, $changes = {}) {
        $db = $db->db if $db isa Registry::DAO;

        my %next = (
            session_id            => $session_id,
            plan_scope            => $plan_scope,
            plan_name             => $plan_name,
            plan_type             => $plan_type,
            pricing_model_type    => $pricing_model_type,
            amount_cents          => $amount_cents,
            currency              => $currency,
            requirements          => $requirements,
            pricing_configuration => $pricing_configuration,
            metadata              => $metadata,
            %$changes,
            plan_family_id => $plan_family_id // $id,
            version        => $version + 1,
        );

        for my $field (qw(requirements pricing_configuration metadata)) {
            $next{$field} = { -json => $next{$field} }
                if ref $next{$field} eq 'HASH';
        }

        my $tx = $db->begin;

        # Retired first. The partial unique index allows one current version per
        # family, so inserting before retiring would be refused -- which is the
        # index doing its job rather than an ordering quirk to work around.
        #
        # The row count IS the guard, and it is checked here rather than against
        # this object's own `superseded_at` field: an in-memory plan read before
        # somebody else revised it still says it is current, so a field test
        # passes and the collision then surfaces as a unique-violation naming an
        # index. Asking the UPDATE how many rows it actually retired is both
        # atomic and able to say what happened.
        my $retired = $db->query(
            'UPDATE pricing_plans SET superseded_at = now()
              WHERE id = ? AND superseded_at IS NULL', $id )->rows;

        unless ($retired) {
            # No explicit rollback: Mojo::Pg::Transaction has no such method and
            # rolls back on destruction unless it was committed, so croaking here
            # is what undoes the UPDATE.
            croak 'Cannot revise a superseded plan version: '
                . "version $version of this plan has already been replaced. "
                . 'Revise the current version instead.';
        }

        my %row = $db->insert( 'pricing_plans', \%next, { returning => '*' } )
            ->expand->hash->%*;

        $tx->commit;

        return blessed($self)->new(%row);
    }

    # The version of this plan that is in effect now.
    sub current_for_family ($class, $db, $family_id) {
        $db = $db->db if $db isa Registry::DAO;
        my $row = $db->select( 'pricing_plans', '*',
            { plan_family_id => $family_id, superseded_at => undef } )
            ->expand->hash;
        return $row ? $class->new(%$row) : undef;
    }

    # Every version of this plan, oldest first.
    method versions ($db) {
        $db = $db->db if $db isa Registry::DAO;
        my $rows = $db->select( 'pricing_plans', '*',
            { plan_family_id => $plan_family_id // $id },
            { -asc => 'version' } )->expand->hashes;
        return [ map { blessed($self)->new(%$_) } @$rows ];
    }
    
    # Override find to use the unqualified table name so the connection's
    # search_path determines the schema (registry or tenant).
    sub find ($class, $db, $filter = {}, $order = { -desc => 'created_at' }) {
        my $table = 'pricing_plans';

        $db = $db->db if $db isa Registry::DAO;
        my $c = $db->select($table, '*', $filter, $order)
            ->expand->hashes->map(sub { $class->new($_->%*) });
        return wantarray ? $c->to_array->@* : $c->first;
    }

    # Add find_by_id for compatibility
    sub find_by_id ($class, $db, $id) {
        return $class->find($db, { id => $id });
    }

    # A better message than the database's, and nothing more.
    #
    # The enforcement is a BEFORE UPDATE trigger on pricing_plans: a croak here
    # would stop only callers that come through the DAO, and `UPDATE
    # pricing_plans SET amount_cents = ...` in psql is both possible and likely --
    # psql is the platform owner's only pricing tooling today (#426), so the
    # person most apt to edit a plan row is the one with no other way to.
    #
    # This override exists because the parent class provides `update`: deleting it
    # would not remove the capability, it would restore it, and the caller would
    # then get a Postgres exception instead of a sentence naming `revise`.
    #
    # No exemption for superseded_at. Retiring a version happens inside `revise`,
    # which writes that column directly, and a second route to it would be
    # flexibility nothing asked for. The trigger permits it; this method does not
    # need to.
    method update ( $db, $data ) {
        croak 'Pricing plan versions are immutable; use revise() to append a new '
            . 'version (fields: ' . join( ', ', sort keys %$data ) . ')';
    }

    # Get the session this pricing belongs to
    method session($db) {
        require Registry::DAO::Event;
        Registry::DAO::Session->find($db, { id => $session_id });
    }
    
    # Create a new pricing plan for a session
    sub create_pricing_plan ($class, $db, $session_id, $data) {
        $data->{session_id} = $session_id;
        $class->create($db, $data);
    }
    
    # Get all pricing plans for a session using the connection's search_path.
    # The plan a tenant signup is allowed to buy, or nothing.
    #
    # This lives on the DAO rather than on a workflow step because two steps
    # need it: PricingPlanSelection refuses a bad choice at selection, and
    # TenantPayment re-reads it where the money actually moves (#347). Having
    # the payment step reach for a sibling step to borrow the rule coupled it
    # to workflow shape, and broke the moment a test drove the payment step in
    # a workflow that had no pricing step.
    sub offered_platform_plan ($class, $db, $plan_id) {
        return unless $plan_id && !ref $plan_id;

        # Shape first, so a malformed value never reaches the query.
        return unless $plan_id =~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

        my $plan;
        eval { $plan = $class->find_by_id( $db, $plan_id ) };
        return unless $plan;

        require Registry::DAO::PricingRelationship;
        my @relationships;
        eval {
            @relationships = Registry::DAO::PricingRelationship->find( $db, {
                provider_id     => '00000000-0000-0000-0000-000000000000',
                pricing_plan_id => $plan_id,
                status          => 'active',
            } );
        };
        return unless @relationships;
        return unless $plan->plan_scope eq 'tenant';

        # A coming-soon plan is on offer to look at, not to buy. It needs an
        # ACTIVE relationship or prepare_pricing_data would not return it to be
        # rendered at all -- which means the only thing between a client and an
        # unlaunched tier was the disabled attribute on a radio button, and a
        # POST does not send radio buttons. These tiers carry a monthly base, so
        # a signup on one creates a subscription for a product that does not
        # exist yet.
        my $metadata = $plan->metadata || {};
        return if $metadata->{coming_soon};

        return $plan;
    }

    # The plans on offer for a session: current versions only, in a defined order.
    #
    # Both halves were defects. Superseded versions would otherwise compete for
    # the best price, so retiring an expensive plan would not stop it being sold.
    # And there was no ORDER BY at all -- which is how the enrolment cart, taking
    # `->[0]`, charged whichever row Postgres happened to return first and priced
    # the same cart differently between runs.
    sub get_pricing_plans ($class, $db, $session_id) {
        $db = $db->db if $db isa Registry::DAO;
        my $results = $db->select(
            'pricing_plans', undef,
            { session_id => $session_id, superseded_at => undef },
            { -asc => [ 'amount_cents', 'created_at', 'id' ] },
        )->expand->hashes;

        return [ map { $class->new(%$_) } @$results ];
    }
    
    # Calculate price based on requirements and context
    method calculate_price ($context = {}) {
        # Check if this plan's requirements are met
        return unless $self->requirements_met($context);
        
        my $price = $amount_cents;

        # Apply any dynamic pricing rules from requirements
        if ($requirements->{percentage_discount}) {
            $price = $price * (1 - $requirements->{percentage_discount} / 100);
        }

        # A discount can land between cents; money cannot.
        return int($price + 0.5);
    }
    
    # Check if plan requirements are met
    # YYYY-MM-DD, YYYYMMDD or an epoch, all reduced to YYYYMMDD so they can be
    # compared as numbers.
    my sub _as_compact_date ($value) {
        return $value unless defined $value;
        return "$1$2$3" if $value =~ /^(\d{4})-(\d{2})-(\d{2})$/;
        return $value   if $value =~ /^\d{8}$/;

        my ( $year, $month, $day ) = ( localtime $value )[ 5, 4, 3 ];
        return sprintf '%04d%02d%02d', $year + 1900, $month + 1, $day;
    }

    # Whether this plan may be used for the cart described by $context.
    #
    # Driven by what the plan DECLARES, not by what it is called. Both checks
    # used to be gated on `$plan_type eq 'early_bird'` / `eq 'family'`, which is
    # the anti-pattern PriceOps' entitlement pillar exists to forbid -- the
    # application knowing plan names. Two concrete consequences of that gating:
    #
    #   * The plan-creation screen offers subscription, per_use, hybrid and
    #     one_time. None of those names appeared here, so any plan built through
    #     the screen fell through every check and behaved as a flat fee no matter
    #     what was configured on it.
    #   * A cutoff date or a minimum-children rule on a plan of any other type
    #     was stored, displayed, and silently not enforced.
    #
    # A requirement present is a requirement honoured. `plan_type` is now a label
    # for people, and adding a plan shape means declaring keys rather than
    # editing this method.
    method requirements_met ($context = {}) {
        # Early bird check
        if ($requirements->{early_bird_cutoff_date}) {
            # Both sides have to be the same shape before they are compared.
            # $today is an epoch unless the caller supplied a date, and an
            # epoch is ten digits where a compacted date is eight -- so
            # $today > $cutoff held for every default call, and the early-bird
            # price was refused unconditionally whenever no date was passed.
            my $cutoff = _as_compact_date( $requirements->{early_bird_cutoff_date} );
            my $today  = _as_compact_date( $context->{date} // time() );

            return 0 if $today > $cutoff;
        }
        
        # Family / sibling minimum
        if ($requirements->{min_children}) {
            my $child_count = $context->{child_count} // 1;
            return 0 if $child_count < $requirements->{min_children};
        }
        
        # Additional requirement checks can be added here
        
        return 1;
    }
    
    # Helper to check if early bird pricing is available
    method is_early_bird_available ($date = time()) {
        # Keyed on the declared cutoff rather than the type name, for the same
        # reason requirements_met is: a plan with a cutoff has one whatever it is
        # called, and a plan called early_bird without one has nothing to offer.
        return 0 unless $requirements->{early_bird_cutoff_date};
        
        # Convert date string to timestamp if needed
        my $cutoff = $requirements->{early_bird_cutoff_date};
        if ($cutoff !~ /^\d+$/) {
            # Parse date string to timestamp
            require Time::Piece;
            $cutoff = Time::Piece->strptime($cutoff, '%Y-%m-%d')->epoch;
        }
        
        return $date <= $cutoff;
    }
    
    # How many months apart each cadence puts its charges. A cadence absent
    # from here is a cadence nothing can schedule, and payment_schedule refuses
    # the plan rather than letting it reach Stripe as a subscription nobody
    # meant to create.
    my %CADENCE_MONTHS = ( monthly => 1, quarterly => 3 );

    # The instalment offer this plan makes, or undef.
    #
    # Declared in pricing_configuration rather than carried by a column and a
    # branch. It replaces installments_allowed/installment_count, which could
    # express "in parts" and nothing else -- no cadence, no surcharge -- so
    # every further payment shape would have cost another boolean and another
    # `if`. That is the plan_type anti-pattern Pillar 4 forbids, and the one
    # calculate_price was just freed from (#427).
    method payment_schedule {
        my $declared = ( $pricing_configuration // {} )->{schedule} or return undef;
        return undef unless ref $declared eq 'HASH';

        my $count = $declared->{count};
        return undef unless defined $count && $count =~ /^[0-9]+$/ && $count > 1;

        my $cadence = $declared->{cadence} // '';
        return undef unless $CADENCE_MONTHS{$cadence};

        return {
            count         => 0 + $count,
            cadence       => $cadence,
            surcharge_pct => 0 + ( $declared->{surcharge_pct} // 0 ),
        };
    }

    # The actual charges: amount and due date for each instalment, or undef when
    # the plan makes no such offer.
    #
    # $total_cents is the cart's, not the plan's: a family enrolling two children
    # pays for two, and the split is of what they owe.
    method instalment_schedule ( $total_cents, %opt ) {
        my $schedule = $self->payment_schedule or return undef;

        my $count = $schedule->{count};
        my $due   = $opt{first_due} // _today();

        # Surcharge first, then split, so the parts sum to what the parent was
        # quoted rather than to the quote plus rounding.
        my $total = $total_cents;
        $total = int( $total * ( 1 + $schedule->{surcharge_pct} / 100 ) + 0.5 )
            if $schedule->{surcharge_pct};

        # Every cent lands somewhere. The even share goes first so the charge a
        # parent sees at checkout is the round number they were quoted, and the
        # remainder rides on the last one. int($total/$count) for all of them --
        # which is what this replaces -- loses up to $count-1 cents per family.
        my $each      = int( $total / $count );
        my $remainder = $total - $each * $count;

        my @parts;
        for my $i ( 1 .. $count ) {
            push @parts, {
                amount_cents => $i == $count ? $each + $remainder : $each,
                due_date     => $due,
            };
            $due = _add_months( $due, $CADENCE_MONTHS{ $schedule->{cadence} } );
        }

        return \@parts;
    }

    sub _today {
        my @t = localtime;
        return sprintf '%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3];
    }

    # Month arithmetic on a YYYY-MM-DD string. Clamped to the end of the target
    # month, because a schedule starting on the 31st must still name a real date
    # in February -- Stripe would otherwise be handed one that does not exist.
    sub _add_months ( $date, $months ) {
        my ( $y, $m, $d ) = $date =~ /^(\d{4})-(\d{2})-(\d{2})$/ or return $date;

        $m += $months;
        while ( $m > 12 ) { $m -= 12; $y++ }

        my @last = ( 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 );
        my $last = $last[ $m - 1 ];
        $last = 29 if $m == 2 && ( $y % 4 == 0 && ( $y % 100 != 0 || $y % 400 == 0 ) );
        $d = $last if $d > $last;

        return sprintf '%04d-%02d-%02d', $y, $m, $d;
    }

    # Format price with currency
    method formatted_price {
        my $dollars = $amount_cents / 100;
        if ($currency eq 'USD') {
            return sprintf('$%.2f', $dollars);
        }
        return sprintf('%.2f %s', $dollars, $currency);
    }
    
    # Get best available price for a session given context
    # The cheapest plan this cart qualifies for, and its price.
    #
    # Returns the PLAN as well as the number, because a charge has to record which
    # version produced it -- `payment_items.pricing_plan_id`. Without that the
    # pricing basis of a charge is unrecoverable: the amount alone does not say
    # which plan it came from, and before versioning the plan could change
    # afterwards anyway.
    #
    # Ties go to the plan get_pricing_plans returns first, which is now ordered
    # rather than arbitrary.
    sub best_plan ($class, $db, $session_id, $context = {}) {
        my $plans = $class->get_pricing_plans($db, $session_id);

        my ( $best_plan, $best_price );
        for my $plan (@$plans) {
            my $price = $plan->calculate_price($context);
            next unless defined $price;
            next if defined $best_price && $price >= $best_price;
            ( $best_plan, $best_price ) = ( $plan, $price );
        }

        return ( $best_plan, $best_price );
    }

    sub get_best_price ($class, $db, $session_id, $context = {}) {
        my ( undef, $price ) = $class->best_plan( $db, $session_id, $context );
        return $price;
    }
}