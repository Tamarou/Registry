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
    method requirements_met ($context = {}) {
        # Early bird check
        if ($plan_type eq 'early_bird' && $requirements->{early_bird_cutoff_date}) {
            my $cutoff = $requirements->{early_bird_cutoff_date};
            my $today = $context->{date} // time();
            
            # Convert dates to comparable format if they're strings
            if ($cutoff && $cutoff =~ /^\d{4}-\d{2}-\d{2}$/) {
                $cutoff =~ s/-//g;  # Convert 2024-05-01 to 20240501
            }
            if ($today && $today =~ /^\d{4}-\d{2}-\d{2}$/) {
                $today =~ s/-//g;   # Convert 2024-04-15 to 20240415
            }
            
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
    # so the installments can sum to less than the plan price -- see
    # Registry::PriceOps::PricingPlan for the breakdown that carries it.
    method installment_amount {
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