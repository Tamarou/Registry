# ABOUTME: Business logic for pricing plan management and installment configuration
# ABOUTME: Handles pricing calculation, installment validation, and plan selection rules
use 5.40.2;
use warnings;
use experimental 'signatures', 'try', 'builtin';

use Object::Pad;
class Registry::PriceOps::PricingPlan {

use Registry::DAO::PricingPlan;

# Business Logic: Validate installment configuration for a pricing plan
method validate_installment_configuration ($pricing_plan_dao) {
    return {
        valid => 0,
        reason => 'Installments not allowed for this plan'
    } unless $pricing_plan_dao->installments_allowed;

    my $installment_count = $pricing_plan_dao->installment_count;
    return {
        valid => 0,
        reason => 'Installment count must be greater than 1'
    } unless defined $installment_count && $installment_count > 1;

    return {
        valid => 1,
        installment_count => $installment_count
    };
}

# Business Logic: Calculate installment breakdown for a pricing plan
method calculate_installment_breakdown ($pricing_plan_dao, $total_amount) {
    my $validation = $self->validate_installment_configuration($pricing_plan_dao);
    die $validation->{reason} unless $validation->{valid};

    my $installment_count = $validation->{installment_count};
    my $base_amount = sprintf("%.2f", $total_amount / $installment_count);

    # Business rule: Handle remainder in the last payment
    my $total_base = $base_amount * $installment_count;
    my $remainder = $total_amount - $total_base;
    my $final_amount = $base_amount + $remainder;

    return {
        installment_count => $installment_count,
        base_installment_amount => $base_amount,
        final_installment_amount => $final_amount,
        total_amount => $total_amount,
        frequency => 'monthly', # Default frequency - could be configurable per plan
        description => "Pay in $installment_count installments of \$$base_amount" .
                      ($remainder != 0 ? " (final payment: \$$final_amount)" : ""),
    };
}

# Business Logic: Get available installment plans for sessions
method get_installment_plans_for_sessions ($db, $session_ids, $total_amount) {
    my @plans;

    for my $session_id (@$session_ids) {
        my @pricing_plans = Registry::DAO::PricingPlan->find($db, { session_id => $session_id });

        for my $plan (@pricing_plans) {
            my $validation = $self->validate_installment_configuration($plan);
            next unless $validation->{valid};

            my $breakdown = $self->calculate_installment_breakdown($plan, $total_amount);

            push @plans, {
                id => $plan->id,
                name => $plan->plan_name,
                session_id => $session_id,
                %$breakdown,
            };
        }
    }

    return \@plans;
}

# Business Logic: Calculate price with any applicable discounts or rules
method calculate_plan_price ($pricing_plan_dao, $args = {}) {
    my $base_amount = $pricing_plan_dao->amount;
    my $child_count = $args->{child_count} || 1;
    my $date = $args->{date} || time();

    # Start with base amount
    my $calculated_price = $base_amount;

    # Apply any pricing rules based on plan requirements
    my $requirements = $pricing_plan_dao->requirements || {};

    # Business rule: Early bird pricing
    if ($pricing_plan_dao->plan_type eq 'early_bird') {
        my $cutoff_date = $requirements->{early_bird_cutoff_date};
        if ($cutoff_date && $date <= $cutoff_date) {
            # Price is already the early bird price
        } else {
            # After cutoff, early bird plans are not available
            return undef;
        }
    }

    # Business rule: Family/sibling discounts
    if ($pricing_plan_dao->plan_type eq 'family' && $child_count > 1) {
        my $sibling_discount = $requirements->{sibling_discount} || 0;
        # Apply discount to additional children
        my $discount_amount = ($child_count - 1) * $sibling_discount;
        $calculated_price = $base_amount - $discount_amount;
    }

    # Ensure price doesn't go negative
    return $calculated_price > 0 ? $calculated_price : 0;
}

# Business Logic: Determine if a plan is currently available
method is_plan_available ($pricing_plan_dao, $args = {}) {
    my $date = $args->{date} || time();
    my $requirements = $pricing_plan_dao->requirements || {};

    # Check early bird cutoff
    if ($pricing_plan_dao->plan_type eq 'early_bird') {
        my $cutoff_date = $requirements->{early_bird_cutoff_date};
        return 0 if $cutoff_date && $date > $cutoff_date;
    }

    # Additional availability rules can be added here
    # e.g., enrollment caps, date ranges, etc.

    return 1;
}

# Business Logic: Get best pricing plan for given criteria
method get_best_plan_for_enrollment ($db, $session_id, $args = {}) {
    my @plans = Registry::DAO::PricingPlan->find($db, { session_id => $session_id });

    my $best_plan;
    my $best_price;

    for my $plan (@plans) {
        next unless $self->is_plan_available($plan, $args);

        my $price = $self->calculate_plan_price($plan, $args);
        next unless defined $price;

        if (!defined $best_price || $price < $best_price) {
            $best_plan = $plan;
            $best_price = $price;
        }
    }

    return $best_plan ? {
        plan => $best_plan,
        calculated_price => $best_price
    } : undef;
}

# Business Logic: Validate pricing plan requirements
method validate_plan_requirements ($pricing_plan_dao, $enrollment_data) {
    my $requirements = $pricing_plan_dao->requirements || {};
    my @errors;

    # Validate family plan requirements
    if ($pricing_plan_dao->plan_type eq 'family') {
        my $child_count = scalar @{$enrollment_data->{children} || []};
        if ($child_count < 2) {
            push @errors, "Family plan requires multiple children";
        }
    }

    # Additional requirement validations can be added here

    return {
        valid => @errors == 0,
        errors => \@errors
    };
}

}

1;