# ABOUTME: Manages relationships between tenants for pricing and billing
# ABOUTME: Handles establishment, modification, and termination of pricing relationships

use 5.40.2;
use warnings;
use experimental 'signatures', 'try', 'builtin';

use Object::Pad;
class Registry::PriceOps::TenantRelationships {

use Registry::DAO::TenantPricingRelationship;
use Registry::DAO::BillingPeriod;
use Registry::DAO::PricingPlan;

# Static method to establish a new relationship
sub establish_relationship ($db, $payer, $payee, $plan) {
    # Validate inputs
    die "Database connection required" unless $db;
    die "Payer tenant ID required" unless $payer;
    die "Payee tenant ID required" unless $payee;
    die "Pricing plan ID required" unless $plan;

    # Get the pricing plan to determine relationship type
    my $pricing_plan = Registry::DAO::PricingPlan->find_by_id($db, $plan);
    die "Pricing plan not found: $plan" unless $pricing_plan;

    # Determine relationship type
    my $relationship_type = _determine_type($pricing_plan);

    # Check for existing active relationship
    my @existing = Registry::DAO::TenantPricingRelationship->find($db, {
        payer_tenant_id => $payer,
        payee_tenant_id => $payee,
        is_active => 1,
    });

    if (@existing) {
        # Deactivate existing relationships
        for my $rel (@existing) {
            $rel->deactivate($db);
        }
    }

    # Create new relationship
    my $relationship = Registry::DAO::TenantPricingRelationship->create($db, {
        payer_tenant_id => $payer,
        payee_tenant_id => $payee,
        pricing_plan_id => $plan,
        relationship_type => $relationship_type,
    });

    return $relationship;
}

# Calculate billing for a period
sub calculate_billing_period ($db, $relationship_id, $period) {
    my $relationship = Registry::DAO::TenantPricingRelationship->find_by_id($db, $relationship_id);
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
    my $relationship = Registry::DAO::TenantPricingRelationship->find_by_id($db, $relationship_id);
    die "Relationship not found: $relationship_id" unless $relationship;

    if ($changes->{action} eq 'cancel') {
        $relationship->deactivate($db);
        return {status => 'cancelled', relationship => $relationship};
    }
    elsif ($changes->{action} eq 'upgrade' || $changes->{action} eq 'downgrade') {
        # Update to new plan
        $relationship->update($db, {
            pricing_plan_id => $changes->{new_plan_id},
        });
        return {status => 'updated', relationship => $relationship};
    }
    elsif ($changes->{action} eq 'pause') {
        $relationship->update($db, {
            is_active => 0,
            metadata => {%{$relationship->metadata}, paused_at => time()},
        });
        return {status => 'paused', relationship => $relationship};
    }
    elsif ($changes->{action} eq 'resume') {
        $relationship->update($db, {
            is_active => 1,
            metadata => {%{$relationship->metadata}, resumed_at => time()},
        });
        return {status => 'resumed', relationship => $relationship};
    }
    else {
        die "Unknown action: $changes->{action}";
    }
}

# Private: Determine relationship type from plan
sub _determine_type ($plan) {
    # Platform relationships
    if ($plan->offering_tenant_id eq '00000000-0000-0000-0000-000000000000') {
        return 'platform_fee';
    }

    # Revenue share
    if ($plan->pricing_model_type eq 'percentage') {
        my $config = $plan->pricing_configuration || {};
        if ($config->{applies_to} && $config->{applies_to} =~ /revenue/) {
            return 'revenue_share';
        }
    }

    # Default to service fee
    return 'service_fee';
}

# Private: Get usage data for billing calculation
sub _get_usage_data ($db, $relationship, $period) {
    my $payer_id = $relationship->payer_tenant_id;
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
        }, $payer_id, $period->{start}, $period->{end});

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
        }, $payer_id, $period->{start}, $period->{end});

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