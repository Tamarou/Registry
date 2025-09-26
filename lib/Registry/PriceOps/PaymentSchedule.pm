# ABOUTME: Business logic for payment schedule management and installment processing
# ABOUTME: Handles installment calculation, scheduling rules, and payment lifecycle management
use 5.40.2;
use warnings;
use experimental 'signatures', 'try', 'builtin';

use Object::Pad;
class Registry::PriceOps::PaymentSchedule {

use Registry::DAO::PaymentSchedule;
use Registry::DAO::ScheduledPayment;
use Registry::Client::Stripe;
use DateTime;
use DateTime::Duration;

field $stripe_client :param = undef;

ADJUST {
    $stripe_client //= Registry::Client::Stripe->new;
}

# Business Logic: Create payment schedule with Stripe subscription
method create_for_enrollment ($db, $args) {
    my $enrollment_id = $args->{enrollment_id} or die "enrollment_id required";
    my $pricing_plan_id = $args->{pricing_plan_id} or die "pricing_plan_id required";
    my $customer_id = $args->{customer_id} or die "customer_id required";
    my $payment_method_id = $args->{payment_method_id} or die "payment_method_id required";
    my $total_amount = $args->{total_amount};
    my $installment_count = $args->{installment_count};
    my $frequency = $args->{frequency} || 'monthly';

    # Business validation
    die "total_amount required" unless defined $total_amount;
    die "installment_count required" unless defined $installment_count;
    die "installment_count must be greater than 1" if $installment_count <= 1;
    die "total_amount must be positive" if $total_amount <= 0;

    # Business rule: Calculate installment amount with proper rounding
    my $installment_amount = $self->calculate_installment_amount($total_amount, $installment_count);

    # Create Stripe subscription first (fail fast if Stripe is unavailable)
    my ($interval, $interval_count) = $self->stripe_interval_from_frequency($frequency);
    my $amount_cents = int($installment_amount * 100);

    my $subscription;
    try {
        $subscription = $stripe_client->create_installment_subscription({
            customer_id => $customer_id,
            payment_method_id => $payment_method_id,
            amount_cents => $amount_cents,
            interval => $interval,
            interval_count => $interval_count,
            description => "Installment payments for enrollment $enrollment_id",
            metadata => {
                enrollment_id => $enrollment_id,
                total_installments => $installment_count,
            },
        });
    }
    catch ($e) {
        die "Failed to create Stripe subscription: $e";
    }

    # Create the database record with subscription ID
    my $schedule_dao = Registry::DAO::PaymentSchedule->create($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan_id,
        stripe_subscription_id => $subscription->{id},
        total_amount => $total_amount,
        installment_amount => $installment_amount,
        installment_count => $installment_count,
        status => 'active'
    });

    # Create scheduled payment tracking records (for status tracking only)
    $self->create_scheduled_payment_trackers($db, $schedule_dao, $subscription);

    return $schedule_dao;
}

# Business Logic: Calculate installment amount with rounding rules
method calculate_installment_amount ($total_amount, $installment_count) {
    # Business rule: Round to 2 decimal places, handle remainder in last payment
    return sprintf("%.2f", $total_amount / $installment_count);
}

# Business Logic: Create payment tracking records (Stripe handles actual scheduling)
method create_scheduled_payment_trackers ($db, $schedule_dao, $subscription) {
    # Create simple tracking records for each installment
    # Stripe subscription handles the actual payment scheduling
    for my $i (1..$schedule_dao->installment_count) {
        Registry::DAO::ScheduledPayment->create($db, {
            payment_schedule_id => $schedule_dao->id,
            installment_number => $i,
            amount => $schedule_dao->installment_amount,
            status => 'pending' # Will be updated via webhooks
        });
    }
}

# This method is no longer needed - subscription is created during schedule creation

# Business Logic: Convert frequency to Stripe intervals
method stripe_interval_from_frequency ($frequency) {
    return ('week', 1) if $frequency eq 'weekly';
    return ('week', 2) if $frequency eq 'bi_weekly';
    return ('month', 1); # monthly default
}

# Business Logic: Check subscription status (payments processed by Stripe)
method check_subscription_status ($db, $schedule_dao) {
    return unless $schedule_dao->stripe_subscription_id;

    try {
        my $subscription = $stripe_client->retrieve_subscription($schedule_dao->stripe_subscription_id);

        # Update schedule status based on subscription status
        if ($subscription->{status} eq 'active') {
            $schedule_dao->update($db, { status => 'active' }) if $schedule_dao->status ne 'active';
        } elsif ($subscription->{status} eq 'past_due') {
            $schedule_dao->update($db, { status => 'past_due' });
        } elsif ($subscription->{status} eq 'canceled') {
            $schedule_dao->update($db, { status => 'cancelled' });
        }

        return $subscription;
    }
    catch ($e) {
        warn "Failed to check subscription status: $e";
        return;
    }
}

# Business Logic: Cancel subscription with proper cleanup
method cancel_subscription ($db, $schedule_dao, $reason = 'requested_by_customer') {
    return unless $schedule_dao->stripe_subscription_id;

    my $subscription;
    try {
        $subscription = $stripe_client->cancel_subscription_with_reason(
            $schedule_dao->stripe_subscription_id,
            $reason
        );
    }
    catch ($e) {
        die "Failed to cancel Stripe subscription: $e";
    }

    # Business rule: Update schedule and cancel pending payments
    $schedule_dao->update($db, { status => 'cancelled' });

    # Cancel all pending scheduled payments
    my @pending = Registry::DAO::ScheduledPayment->find($db, {
        payment_schedule_id => $schedule_dao->id,
        status => 'pending'
    });

    for my $payment (@pending) {
        $payment->update($db, { status => 'cancelled' });
    }

    return $subscription;
}

# Business Logic: Mark schedule as completed
method mark_completed ($db, $schedule_dao) {
    $schedule_dao->update($db, { status => 'completed' });

    # Cancel subscription if it exists
    if ($schedule_dao->stripe_subscription_id) {
        try {
            $stripe_client->cancel_subscription_with_reason(
                $schedule_dao->stripe_subscription_id,
                'Payment schedule completed'
            );
        }
        catch ($e) {
            # Log but don't fail if subscription cancellation fails
            warn "Failed to cancel completed subscription: $e";
        }
    }
}

# Business Logic: Suspend schedule due to payment failures
method suspend ($db, $schedule_dao, $reason = 'payment_failure') {
    $schedule_dao->update($db, { status => 'suspended' });

    # Pause subscription if it exists
    if ($schedule_dao->stripe_subscription_id) {
        try {
            $stripe_client->pause_subscription($schedule_dao->stripe_subscription_id, $reason);
        }
        catch ($e) {
            warn "Failed to pause subscription: $e";
        }
    }
}

# Business Logic: Reactivate suspended schedule
method reactivate ($db, $schedule_dao) {
    die "Cannot reactivate completed schedule" if $schedule_dao->status eq 'completed';

    $schedule_dao->update($db, { status => 'active' });

    # Resume subscription if it exists
    if ($schedule_dao->stripe_subscription_id) {
        try {
            $stripe_client->resume_subscription($schedule_dao->stripe_subscription_id);
        }
        catch ($e) {
            warn "Failed to resume subscription: $e";
        }
    }
}

# Business Queries: Find schedules with payment issues (use Stripe status)
method find_schedules_with_payment_issues ($db) {
    # Find schedules that are past_due or suspended
    my @schedules = Registry::DAO::PaymentSchedule->find($db, {
        status => ['past_due', 'suspended']
    });

    return \@schedules;
}

}

1;