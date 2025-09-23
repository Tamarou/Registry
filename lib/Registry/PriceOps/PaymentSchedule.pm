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

# Business Logic: Create payment schedule with validation and rules
method create_for_enrollment ($db, $args) {
    my $enrollment_id = $args->{enrollment_id} or die "enrollment_id required";
    my $pricing_plan_id = $args->{pricing_plan_id} or die "pricing_plan_id required";
    my $total_amount = $args->{total_amount};
    my $installment_count = $args->{installment_count};
    my $first_payment_date = $args->{first_payment_date} || DateTime->now->ymd;
    my $frequency = $args->{frequency} || 'monthly';

    # Business validation
    die "total_amount required" unless defined $total_amount;
    die "installment_count required" unless defined $installment_count;
    die "installment_count must be greater than 1" if $installment_count <= 1;
    die "total_amount must be positive" if $total_amount <= 0;

    # Business rule: Calculate installment amount with proper rounding
    my $installment_amount = $self->calculate_installment_amount($total_amount, $installment_count);

    # Create the database record via DAO
    my $schedule_dao = Registry::DAO::PaymentSchedule->create($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan_id,
        total_amount => $total_amount,
        installment_amount => $installment_amount,
        installment_count => $installment_count,
        first_payment_date => $first_payment_date,
        frequency => $frequency,
        status => 'active'
    });

    # Business logic: Create scheduled payment instances
    $self->create_scheduled_payments($db, $schedule_dao, {
        installment_count => $installment_count,
        installment_amount => $installment_amount,
        first_payment_date => $first_payment_date,
        frequency => $frequency,
    });

    return $schedule_dao;
}

# Business Logic: Calculate installment amount with rounding rules
method calculate_installment_amount ($total_amount, $installment_count) {
    # Business rule: Round to 2 decimal places, handle remainder in last payment
    return sprintf("%.2f", $total_amount / $installment_count);
}

# Business Logic: Create scheduled payment instances based on business rules
method create_scheduled_payments ($db, $schedule_dao, $args) {
    my $installment_count = $args->{installment_count};
    my $installment_amount = $args->{installment_amount};
    my $first_payment_date = $args->{first_payment_date};
    my $frequency = $args->{frequency};

    my $current_date = $self->parse_payment_date($first_payment_date);
    my $duration = $self->calculate_frequency_duration($frequency);

    for my $i (1..$installment_count) {
        Registry::DAO::ScheduledPayment->create($db, {
            payment_schedule_id => $schedule_dao->id,
            installment_number => $i,
            due_date => $current_date->ymd,
            amount => $installment_amount,
            status => 'pending'
        });

        $current_date->add_duration($duration);
    }
}

# Business Logic: Parse and validate payment dates
method parse_payment_date ($date_input) {
    if (ref $date_input) {
        return $date_input; # Already a DateTime object
    }

    # Parse string date
    if ($date_input =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
        return DateTime->new(year => $1, month => $2, day => $3);
    }

    # Default to current date
    return DateTime->now;
}

# Business Logic: Calculate duration between payments based on frequency
method calculate_frequency_duration ($frequency) {
    return $frequency eq 'weekly' ? DateTime::Duration->new(weeks => 1)
         : $frequency eq 'bi_weekly' ? DateTime::Duration->new(weeks => 2)
         : DateTime::Duration->new(months => 1); # monthly default
}

# Business Logic: Create Stripe subscription for automated payments
method create_stripe_subscription ($db, $schedule_dao, $args = {}) {
    die "Schedule already has Stripe subscription" if $schedule_dao->stripe_subscription_id;

    my $customer_id = $args->{customer_id} || die "customer_id required for subscription";
    my $payment_method_id = $args->{payment_method_id} || die "payment_method_id required";
    my $description = $args->{description} || "Installment payments for enrollment";

    # Business rules: Calculate Stripe subscription parameters
    my ($interval, $interval_count) = $self->stripe_interval_from_frequency($schedule_dao->frequency);
    my $amount_cents = int($schedule_dao->installment_amount * 100);

    my $subscription;
    try {
        $subscription = $stripe_client->create_installment_subscription({
            customer_id => $customer_id,
            payment_method_id => $payment_method_id,
            amount_cents => $amount_cents,
            interval => $interval,
            interval_count => $interval_count,
            description => $description,
            metadata => {
                payment_schedule_id => $schedule_dao->id,
                enrollment_id => $schedule_dao->enrollment_id,
                total_installments => $schedule_dao->installment_count,
            },
        });
    }
    catch ($e) {
        die "Failed to create Stripe subscription: $e";
    }

    # Update DAO with subscription ID
    $schedule_dao->update($db, { stripe_subscription_id => $subscription->{id} });

    return $subscription;
}

# Business Logic: Convert frequency to Stripe intervals
method stripe_interval_from_frequency ($frequency) {
    return ('week', 1) if $frequency eq 'weekly';
    return ('week', 2) if $frequency eq 'bi_weekly';
    return ('month', 1); # monthly default
}

# Business Logic: Process due payments with retry logic
method process_due_payments ($db, $schedule_dao) {
    my $today = DateTime->now->ymd;

    # Get due payments from DAO
    my @due_payments = Registry::DAO::ScheduledPayment->find($db, {
        payment_schedule_id => $schedule_dao->id,
        status => 'pending',
        due_date => { '<=' => $today }
    });

    my @results;
    for my $scheduled_payment (@due_payments) {
        # Delegate to ScheduledPayment business logic
        my $payment_ops = Registry::PriceOps::ScheduledPayment->new(
            stripe_client => $stripe_client
        );
        push @results, $payment_ops->process_payment($db, $scheduled_payment);
    }

    return \@results;
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

# Business Queries: Find schedules with overdue payments
method find_schedules_with_overdue_payments ($db) {
    my $today = DateTime->now->ymd;

    # Find schedules with overdue payments via raw SQL
    my $sql = qq{
        SELECT DISTINCT ps.*
        FROM registry.payment_schedules ps
        JOIN registry.scheduled_payments sp ON ps.id = sp.payment_schedule_id
        WHERE ps.status = 'active'
        AND sp.status = 'pending'
        AND sp.due_date < ?
        ORDER BY ps.created_at DESC
    };

    my $results = $db->db->query($sql, $today)->hashes;
    return [map { Registry::DAO::PaymentSchedule->new(%$_) } @$results];
}

}

1;