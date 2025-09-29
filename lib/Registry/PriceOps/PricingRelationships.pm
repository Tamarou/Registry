# ABOUTME: Manages unified pricing relationships with complete event sourcing audit trail
# ABOUTME: Handles platform, B2C, and B2B relationships with compliance tracking

use 5.40.2;
use warnings;
use experimental 'signatures', 'try', 'builtin';

use Object::Pad;
class Registry::PriceOps::PricingRelationships {

use Registry::DAO::PricingRelationship;
use Registry::DAO::BillingPeriod;
use Registry::DAO::PricingPlan;
use Registry::DAO::User;
use Registry::DAO::PricingRelationshipEvent;

# Static method to establish a new relationship
# Now accepts either tenant IDs (for B2B) or user IDs (for B2C/platform)
sub establish_relationship ($db, $provider, $consumer, $plan, $type = 'auto') {
    # Validate inputs
    die "Database connection required" unless $db;
    die "Provider ID required" unless $provider;
    die "Consumer ID required" unless $consumer;
    die "Pricing plan ID required" unless $plan;

    # Get the pricing plan
    my $pricing_plan = Registry::DAO::PricingPlan->find_by_id($db, $plan);
    die "Pricing plan not found: $plan" unless $pricing_plan;

    # Determine if consumer is a user ID or needs to be resolved
    my $consumer_id;
    if ($type eq 'b2b' || $type eq 'tenant') {
        # For B2B, find or create admin user for the tenant
        require Registry::DAO::Tenant;
        my $tenant = Registry::DAO::Tenant->find_by_id($db, $consumer);
        die "Tenant not found: $consumer" unless $tenant;

        # Find or create admin user
        my @admins = Registry::DAO::User->find($db, {
            tenant_id => $consumer,
            user_type => ['admin', 'tenant_admin'],
        });

        if (@admins) {
            $consumer_id = $admins[0]->id;
        } else {
            # Create admin user for tenant
            my $admin = Registry::DAO::User->create($db, {
                name => $tenant->name . ' Admin',
                email => 'admin+' . $tenant->id . '@registry.system',
                tenant_id => $tenant->id,
                user_type => 'admin',
            });
            $consumer_id = $admin->id;
        }
    } else {
        # Direct user ID for B2C/platform relationships
        $consumer_id = $consumer;
    }

    # Check for existing active relationship
    if (Registry::DAO::PricingRelationship->exists_between($db, $provider, $consumer_id)) {
        # Cancel existing relationships
        my @existing = Registry::DAO::PricingRelationship->find($db, {
            provider_id => $provider,
            consumer_id => $consumer_id,
            status => ['active', 'pending'],
        });

        for my $rel (@existing) {
            $rel->cancel($db);
        }
    }

    # Create new relationship
    my $relationship = Registry::DAO::PricingRelationship->create($db, {
        provider_id => $provider,
        consumer_id => $consumer_id,
        pricing_plan_id => $plan,
        status => 'active',
    });

    # Record creation event for audit trail
    Registry::DAO::PricingRelationshipEvent->record_creation(
        $db,
        $relationship->id,
        $consumer_id,  # Actor is the consumer initiating the relationship
        {
            provider_id => $provider,
            consumer_id => $consumer_id,
            pricing_plan_id => $plan,
            relationship_type => $type,
        }
    );

    return $relationship;
}

# Calculate billing for a period
sub calculate_billing_period ($db, $relationship_id, $period) {
    my $relationship = Registry::DAO::PricingRelationship->find_by_id($db, $relationship_id);
    die "Relationship not found: $relationship_id" unless $relationship;

    my $plan = $relationship->get_pricing_plan($db);

    # Get usage data for the period
    my $usage_data = _get_usage_data($db, $relationship, $period);

    # Calculate amount
    my $amount = _calculate_amount($plan, $usage_data);

    # Create billing period
    my $billing_period = Registry::DAO::BillingPeriod->create($db, {
        pricing_relationship_id => $relationship_id,
        period_start => $period->{start},
        period_end => $period->{end},
        calculated_amount => $amount,
    });

    return $billing_period;
}

# Handle relationship changes (upgrades, downgrades, cancellations)
sub handle_relationship_changes ($db, $relationship_id, $changes) {
    my $relationship = Registry::DAO::PricingRelationship->find_by_id($db, $relationship_id);
    die "Relationship not found: $relationship_id" unless $relationship;

    if ($changes->{action} eq 'cancel') {
        $relationship->cancel($db);

        # Record termination event
        Registry::DAO::PricingRelationshipEvent->record_termination(
            $db,
            $relationship_id,
            $changes->{actor_id} || $relationship->consumer_id,
            $changes->{reason} || 'User requested cancellation'
        );

        return {status => 'cancelled', relationship => $relationship};
    }
    elsif ($changes->{action} eq 'upgrade' || $changes->{action} eq 'downgrade') {
        my $old_plan_id = $relationship->pricing_plan_id;

        # Update to new plan
        $relationship->update($db, {
            pricing_plan_id => $changes->{new_plan_id},
        });

        # Record plan change event
        Registry::DAO::PricingRelationshipEvent->record_plan_change(
            $db,
            $relationship_id,
            $changes->{actor_id} || $relationship->consumer_id,
            $old_plan_id,
            $changes->{new_plan_id},
            $changes->{reason} || "Customer ${\$changes->{action}}"
        );

        return {status => 'updated', relationship => $relationship};
    }
    elsif ($changes->{action} eq 'pause') {
        $relationship->suspend($db);

        # Record suspension event
        Registry::DAO::PricingRelationshipEvent->record_suspension(
            $db,
            $relationship_id,
            $changes->{actor_id} || $relationship->consumer_id,
            $changes->{reason} || 'User requested pause'
        );

        return {status => 'suspended', relationship => $relationship};
    }
    elsif ($changes->{action} eq 'resume') {
        $relationship->activate($db);

        # Record activation event
        Registry::DAO::PricingRelationshipEvent->record_activation(
            $db,
            $relationship_id,
            $changes->{actor_id} || $relationship->consumer_id,
            $changes->{reason} || 'User requested resumption'
        );

        return {status => 'active', relationship => $relationship};
    }
    else {
        die "Unknown action: $changes->{action}";
    }
}

# Get complete audit trail for a relationship
sub get_audit_trail ($db, $relationship_id) {
    return Registry::DAO::PricingRelationshipEvent->get_audit_trail($db, $relationship_id);
}

# Check if a state transition is valid
sub can_transition_state ($db, $relationship_id, $from_state, $to_state) {
    return Registry::DAO::PricingRelationshipEvent->can_transition(
        $db,
        $relationship_id,
        $from_state,
        $to_state
    );
}

# Get relationship state at a specific point in time
sub get_relationship_state_at ($db, $relationship_id, $timestamp) {
    return Registry::DAO::PricingRelationshipEvent->get_state_at_time(
        $db,
        $relationship_id,
        $timestamp
    );
}


# Private: Get usage data for billing calculation
sub _get_usage_data ($db, $relationship, $period) {
    # Get the consumer's tenant (if B2B) or use provider for B2C
    my $consumer_tenant = $relationship->get_consumer_tenant($db);
    my $tenant_id = $consumer_tenant ? $consumer_tenant->id : $relationship->provider_id;
    my $plan = $relationship->get_pricing_plan($db);
    my $config = $plan->pricing_configuration || {};

    my $usage_data = {};

    # Get customer payments if needed
    if ($config->{applies_to} && $config->{applies_to} eq 'customer_payments') {
        # Query payments for the tenant during the period
        my $result = $db->query(q{
            SELECT COALESCE(SUM(amount), 0) as total
            FROM registry.payments
            WHERE tenant_id = ?
              AND created_at >= ?
              AND created_at <= ?
              AND status = 'completed'
        }, $tenant_id, $period->{start}, $period->{end});

        $usage_data->{customer_payments} = $result->hash->{total} || 0;
    }

    # Get transaction data if needed
    if ($plan->pricing_model_type eq 'transaction_fee') {
        my $result = $db->query(q{
            SELECT
                COUNT(*) as count,
                COALESCE(SUM(amount), 0) as volume
            FROM registry.payments
            WHERE tenant_id = ?
              AND created_at >= ?
              AND created_at <= ?
              AND status = 'completed'
        }, $tenant_id, $period->{start}, $period->{end});

        my $row = $result->hash;
        $usage_data->{transaction_count} = $row->{count} || 0;
        $usage_data->{transaction_volume} = $row->{volume} || 0;
    }

    # Get program revenue if needed
    if ($config->{applies_to} && $config->{applies_to} eq 'program_revenue') {
        # Similar query for program-specific revenue
        $usage_data->{program_revenue} = 0; # Placeholder
    }

    return $usage_data;
}

# Private: Calculate amount based on plan and usage
sub _calculate_amount ($plan, $usage_data) {
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
        my $count = $usage_data->{transaction_count} || 0;
        my $volume = $usage_data->{transaction_volume} || 0;

        return sprintf("%.2f", ($per_transaction * $count) + ($volume * $percentage));
    }
    elsif ($model eq 'hybrid') {
        my $base = $config->{monthly_base} || $plan->amount;
        my $percentage = $config->{percentage} || 0;
        my $applies_to = $config->{applies_to} || 'customer_payments';
        my $variable = ($usage_data->{$applies_to} || 0) * $percentage;

        return sprintf("%.2f", $base + $variable);
    }
    else {
        die "Unsupported pricing model: $model";
    }
}

}

1;