use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::PricingPlan :isa(Registry::DAO::Object) {
    use Carp qw( croak );
    use Mojo::JSON qw( decode_json encode_json );
    use List::Util qw( min );
    
    field $id :param :reader;
    field $session_id :param :reader = undef;
    field $plan_scope :param :reader = 'customer';
    field $plan_name :param :reader;
    field $plan_type :param :reader = 'standard';
    field $pricing_model_type :param :reader = 'fixed';
    field $amount_cents :param :reader = 0;
    field $currency :param :reader = 'USD';
    field $installments_allowed :param :reader = 0;
    field $installment_count :param :reader = undef;
    field $requirements :param :reader = {};
    field $pricing_configuration :param :reader = {};
    field $metadata :param :reader = {};
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
        
        # Validate installment configuration
        if ($installments_allowed && (!defined $installment_count || $installment_count <= 1)) {
            croak "Installment count must be greater than 1 when installments are allowed";
        }
        if (!$installments_allowed && defined $installment_count) {
            croak "Installment count should not be set when installments are not allowed";
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
        $data->{installments_allowed} //= 0;
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
            return $class->new(%result);
        }
        catch ($e) {
            croak "Failed to create pricing plan: $e";
        }
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

    method update ($db, $data) {
        # Encode JSON fields
        for my $field (qw(requirements pricing_configuration metadata)) {
            if (exists $data->{$field} && ref $data->{$field} eq 'HASH') {
                $data->{$field} = { -json => $data->{$field} };
            }
        }

        $self->SUPER::update($db, $data);
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

    sub get_pricing_plans ($class, $db, $session_id) {
        my $table = 'pricing_plans';

        $db = $db->db if $db isa Registry::DAO;
        my $results = $db->select($table, undef, { session_id => $session_id })->hashes;

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

    method requirements_met ($context = {}) {
        # Early bird check
        if ($plan_type eq 'early_bird' && $requirements->{early_bird_cutoff_date}) {
            # Both sides have to be the same shape before they are compared.
            # $today is an epoch unless the caller supplied a date, and an
            # epoch is ten digits where a compacted date is eight -- so
            # $today > $cutoff held for every default call, and the early-bird
            # price was refused unconditionally whenever no date was passed.
            my $cutoff = _as_compact_date( $requirements->{early_bird_cutoff_date} );
            my $today  = _as_compact_date( $context->{date} // time() );

            return 0 if $today > $cutoff;
        }
        
        # Family plan check
        if ($plan_type eq 'family' && $requirements->{min_children}) {
            my $child_count = $context->{child_count} // 1;
            return 0 if $child_count < $requirements->{min_children};
        }
        
        # Additional requirement checks can be added here
        
        return 1;
    }
    
    # Helper to check if early bird pricing is available
    method is_early_bird_available ($date = time()) {
        return 0 unless $plan_type eq 'early_bird';
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
    
    # Get installment amount, in cents. Integer division drops the remainder,
    # so the installments can sum to less than the plan price. Nothing collects
    # installments today; no leg drops these registry.pricing_plans columns.
    method installment_amount_cents {
        return $amount_cents unless $installments_allowed && $installment_count;
        return int($amount_cents / $installment_count);
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
    sub get_best_price ($class, $db, $session_id, $context = {}) {
        my $plans = $class->get_pricing_plans($db, $session_id);
        
        my @applicable_prices;
        for my $plan (@$plans) {
            my $price = $plan->calculate_price($context);
            push @applicable_prices, $price if defined $price;
        }
        
        return @applicable_prices ? min(@applicable_prices) : undef;
    }
}