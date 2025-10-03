# ABOUTME: Unified pricing engine for all tenant-to-tenant pricing operations
# ABOUTME: Handles platform fees, cross-tenant services, and revenue sharing

use 5.40.2;
use warnings;
use experimental 'signatures', 'try', 'builtin';

use Object::Pad;
class Registry::PriceOps::UnifiedPricingEngine {

use Registry::DAO::PricingPlan;
use Registry::DAO::PricingRelationship;
use Registry::DAO::BillingPeriod;
use Mojo::JSON qw(encode_json decode_json);

field $db :param :reader;

# Business Logic: Subscribe a consumer to a pricing plan
method subscribe_to_plan ($consumer_id, $plan_id, $type = 'auto') {
    # Get the pricing plan
    my $plan = Registry::DAO::PricingPlan->find_by_id($db, $plan_id);
    die "Pricing plan not found: $plan_id" unless $plan;

    # Platform is the default provider for now
    # TODO: Determine provider from existing relationships or metadata
    my $provider_id = '00000000-0000-0000-0000-000000000000';

    # Handle tenant subscriptions by finding/creating admin user
    my $final_consumer_id = $consumer_id;
    if ($type eq 'tenant') {
        require Registry::DAO::Tenant;
        require Registry::DAO::User;
        my $tenant = Registry::DAO::Tenant->find_by_id($db, $consumer_id);
        die "Tenant not found: $consumer_id" unless $tenant;

        # Find admin user
        my @admins = Registry::DAO::User->find($db, {
            tenant_id => $consumer_id,
            user_type => ['admin', 'tenant_admin'],
        });

        if (@admins) {
            $final_consumer_id = $admins[0]->id;
        } else {
            # Create admin user
            my $admin = Registry::DAO::User->create($db, {
                name => $tenant->name . ' Admin',
                email => 'admin+' . $tenant->id . '@registry.system',
                tenant_id => $tenant->id,
                user_type => 'admin',
            });
            $final_consumer_id = $admin->id;
        }
    }

    # Create the relationship
    my $relationship = Registry::DAO::PricingRelationship->create($db, {
        provider_id => $provider_id,
        consumer_id => $final_consumer_id,
        pricing_plan_id => $plan_id,
        status => 'active',
    });

    return $relationship;
}

# Business Logic: Calculate fees for a billing period
method calculate_fees ($relationship_id, $period, $usage_data) {
    # Get the relationship
    my $relationship = Registry::DAO::PricingRelationship->find_by_id($db, $relationship_id);
    die "Relationship not found: $relationship_id" unless $relationship;

    # Get the pricing plan
    my $plan = $relationship->get_pricing_plan($db);

    # Calculate amount based on pricing model
    my $amount = $self->_calculate_amount($plan, $usage_data);

    # Create billing period record
    my $billing_period = Registry::DAO::BillingPeriod->create($db, {
        pricing_relationship_id => $relationship_id,
        period_start => $period->{start},
        period_end => $period->{end},
        calculated_amount => $amount,
        metadata => encode_json({
            usage_data => $usage_data,
            pricing_model => $plan->pricing_model_type,
        }),
    });

    return $billing_period;
}

# Business Logic: Create a new pricing plan
method create_pricing_plan ($offering_tenant, $configuration) {
    my $plan_data = {
        plan_scope => $configuration->{plan_scope} || 'customer',
        plan_name => $configuration->{plan_name},
        plan_type => $configuration->{plan_type} || 'custom',
        pricing_model_type => $configuration->{pricing_model_type} || 'fixed',
        amount => $configuration->{amount} || 0,
        currency => $configuration->{currency} || 'USD',
        pricing_configuration => $configuration->{pricing_configuration} || {},
        metadata => $configuration->{metadata} || {},
    };

    return Registry::DAO::PricingPlan->create($db, $plan_data);
}

# Business Logic: Switch a relationship to a new plan
method process_plan_switch ($relationship_id, $new_plan_id) {
    my $relationship = Registry::DAO::PricingRelationship->find_by_id($db, $relationship_id);
    die "Relationship not found: $relationship_id" unless $relationship;

    # Get new plan
    my $new_plan = Registry::DAO::PricingPlan->find_by_id($db, $new_plan_id);
    die "New pricing plan not found: $new_plan_id" unless $new_plan;

    # Update relationship
    $relationship->update($db, {
        pricing_plan_id => $new_plan_id,
    });

    return $relationship;
}

# Business Logic: Get available plans for a tenant
method get_available_plans_for_tenant ($tenant_id, $filters = {}) {
    my $where = {
        plan_scope => 'tenant',
    };

    # Add filters
    if ($filters->{plan_scope}) {
        $where->{plan_scope} = $filters->{plan_scope};
    }

    # Get all plans with the specified scope
    # Relationships determine who can access them
    my @plans = Registry::DAO::PricingPlan->find($db, $where);

    return \@plans;
}

# Business Logic: Get all relationships for a tenant
method get_tenant_relationships ($tenant_id, $include_inactive = 0) {
    my $where = {
        -or => [
            {provider_id => $tenant_id},
            {consumer_id => $tenant_id},
        ],
    };

    unless ($include_inactive) {
        $where->{status} = ['active', 'pending'];
    }

    my @relationships = Registry::DAO::PricingRelationship->find($db, $where);
    return \@relationships;
}

# Private: Determine relationship type from plan
method _determine_relationship_type ($plan) {
    # Platform scope indicates platform fee
    if ($plan->plan_scope eq 'platform') {
        return 'platform_fee';
    }

    # Revenue share relationships
    if ($plan->pricing_model_type eq 'percentage' &&
        $plan->pricing_configuration->{applies_to} &&
        $plan->pricing_configuration->{applies_to} =~ /revenue/) {
        return 'revenue_share';
    }

    # Transaction fee relationships
    if ($plan->pricing_model_type eq 'transaction_fee') {
        return 'service_fee';
    }

    # Default
    return 'service_fee';
}

# Private: Calculate amount based on pricing model
method _calculate_amount ($plan, $usage_data) {
    my $model = $plan->pricing_model_type;
    my $config = $plan->pricing_configuration || {};

    if ($model eq 'fixed') {
        return $plan->amount;
    }
    elsif ($model eq 'percentage') {
        my $percentage = $config->{percentage} || ($plan->amount / 100);
        my $applies_to = $config->{applies_to} || 'customer_payments';
        my $base_amount = $usage_data->{$applies_to} || 0;
        return sprintf("%.2f", $base_amount * $percentage);
    }
    elsif ($model eq 'transaction_fee') {
        my $per_transaction = $config->{per_transaction} || 0;
        my $percentage = $config->{percentage} || 0;
        my $transaction_count = $usage_data->{transaction_count} || 0;
        my $transaction_volume = $usage_data->{transaction_volume} || 0;

        my $fixed_fee = $per_transaction * $transaction_count;
        my $percentage_fee = $transaction_volume * $percentage;

        return sprintf("%.2f", $fixed_fee + $percentage_fee);
    }
    elsif ($model eq 'hybrid') {
        my $base = $config->{monthly_base} || $plan->amount;
        my $percentage = $config->{percentage} || 0;
        my $applies_to = $config->{applies_to} || 'customer_payments';
        my $variable_amount = ($usage_data->{$applies_to} || 0) * $percentage;

        return sprintf("%.2f", $base + $variable_amount);
    }
    elsif ($model eq 'tiered') {
        # Future implementation for tiered pricing
        die "Tiered pricing not yet implemented";
    }
    else {
        die "Unknown pricing model: $model";
    }
}

}

1;