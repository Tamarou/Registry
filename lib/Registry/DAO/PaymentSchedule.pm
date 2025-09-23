# ABOUTME: Payment schedule management for installment payments with enrollment tracking
# ABOUTME: Handles creation of payment schedules and Stripe subscription integration
use 5.40.2;
use warnings;
use experimental 'signatures', 'try', 'builtin';

use Object::Pad;
class Registry::DAO::PaymentSchedule :isa(Registry::DAO::Object) {

use Registry::Service::Stripe;
use Registry::DAO::ScheduledPayment;
use Registry::DAO::Payment;
use Mojo::JSON qw(encode_json decode_json);
use DateTime;
use DateTime::Duration;

field $id :param :reader = undef;
field $enrollment_id :param :reader = undef;
field $pricing_plan_id :param :reader = undef;
field $stripe_subscription_id :param :reader = undef;
field $total_amount :param :reader = 0;
field $installment_amount :param :reader = 0;
field $installment_count :param :reader = 0;
field $first_payment_date :param :reader = undef;
field $frequency :param :reader = 'monthly';
field $status :param :reader = 'active';
field $created_at :param :reader = undef;
field $updated_at :param :reader = undef;

field $_stripe_client = undef;

sub table { 'registry.payment_schedules' }

method stripe_client {
    return $_stripe_client if $_stripe_client;

    my $api_key = $ENV{STRIPE_SECRET_KEY} || die "STRIPE_SECRET_KEY not set";
    my $webhook_secret = $ENV{STRIPE_WEBHOOK_SECRET};

    eval {
        $_stripe_client = Registry::Service::Stripe->new(
            api_key => $api_key,
            webhook_secret => $webhook_secret,
        );
    };

    if ($@) {
        die "Stripe client initialization failed: $@";
    }

    return $_stripe_client;
}

sub create_for_enrollment ($class, $db, $args) {
    $db = $db->db if $db isa Registry::DAO;

    my $enrollment_id = $args->{enrollment_id} or die "enrollment_id required";
    my $pricing_plan_id = $args->{pricing_plan_id} or die "pricing_plan_id required";
    my $total_amount = $args->{total_amount};
    my $installment_count = $args->{installment_count};
    my $first_payment_date = $args->{first_payment_date} || DateTime->now->ymd;

    die "total_amount required" unless defined $total_amount;
    die "installment_count required" unless defined $installment_count;

    die "installment_count must be greater than 1" if $installment_count <= 1;
    die "total_amount must be positive" if $total_amount <= 0;

    # Calculate installment amount (round to 2 decimal places)
    my $installment_amount = sprintf("%.2f", $total_amount / $installment_count);

    # Create the payment schedule
    my $schedule = $class->create($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan_id,
        total_amount => $total_amount,
        installment_amount => $installment_amount,
        installment_count => $installment_count,
        first_payment_date => $first_payment_date,
        frequency => $args->{frequency} || 'monthly',
        status => 'active'
    });

    # Create individual scheduled payments
    $schedule->_create_scheduled_payments($db);

    return $schedule;
}

method _create_scheduled_payments ($db) {
    my $current_date = DateTime->from_epoch(epoch => time());
    if ($first_payment_date) {
        # Parse first payment date if it's a string
        if (!ref $first_payment_date) {
            my ($year, $month, $day) = split /-/, $first_payment_date;
            $current_date = DateTime->new(year => $year, month => $month, day => $day);
        }
    }

    my $duration = $frequency eq 'weekly' ? DateTime::Duration->new(weeks => 1)
                 : $frequency eq 'bi_weekly' ? DateTime::Duration->new(weeks => 2)
                 : DateTime::Duration->new(months => 1); # monthly

    for my $i (1..$installment_count) {
        Registry::DAO::ScheduledPayment->create($db, {
            payment_schedule_id => $self->id,
            installment_number => $i,
            due_date => $current_date->ymd,
            amount => $installment_amount,
            status => 'pending'
        });

        $current_date->add_duration($duration);
    }
}

method scheduled_payments ($db) {
    return Registry::DAO::ScheduledPayment->find($db,
        { payment_schedule_id => $self->id },
        { order_by => 'installment_number' }
    );
}

method pending_payments ($db) {
    return Registry::DAO::ScheduledPayment->find($db,
        {
            payment_schedule_id => $self->id,
            status => 'pending'
        },
        { order_by => 'due_date' }
    );
}

method overdue_payments ($db) {
    my $today = DateTime->now->ymd;
    return Registry::DAO::ScheduledPayment->find($db,
        {
            payment_schedule_id => $self->id,
            status => 'pending',
            due_date => { '<' => $today }
        },
        { order_by => 'due_date' }
    );
}

method process_due_payments ($db) {
    my $today = DateTime->now->ymd;
    my @due_payments = Registry::DAO::ScheduledPayment->find($db, {
        payment_schedule_id => $self->id,
        status => 'pending',
        due_date => { '<=' => $today }
    });

    my @results;
    for my $scheduled_payment (@due_payments) {
        push @results, $scheduled_payment->process($db);
    }

    return \@results;
}

method create_stripe_subscription ($db, $args = {}) {
    die "Schedule already has Stripe subscription" if $stripe_subscription_id;

    my $customer_id = $args->{customer_id} || die "customer_id required for subscription";
    my $payment_method_id = $args->{payment_method_id} || die "payment_method_id required";
    my $description = $args->{description} || "Installment payments for enrollment";

    # Calculate subscription interval based on frequency
    my ($interval, $interval_count) = $frequency eq 'weekly' ? ('week', 1)
                                    : $frequency eq 'bi_weekly' ? ('week', 2)
                                    : ('month', 1); # monthly

    my $subscription;
    try {
        $subscription = $self->stripe_client->create_subscription({
            customer => $customer_id,
            default_payment_method => $payment_method_id,
            items => [{
                price_data => {
                    currency => 'usd',
                    product_data => {
                        name => $description,
                    },
                    unit_amount => int($installment_amount * 100), # Convert to cents
                    recurring => {
                        interval => $interval,
                        interval_count => $interval_count,
                    },
                },
                quantity => 1,
            }],
            metadata => {
                payment_schedule_id => $self->id,
                enrollment_id => $enrollment_id,
                total_installments => $installment_count,
            },
        });
    }
    catch ($e) {
        die "Failed to create Stripe subscription: $e";
    }

    # Update schedule with subscription ID
    $stripe_subscription_id = $subscription->{id};
    $self->update($db, { stripe_subscription_id => $stripe_subscription_id });

    return $subscription;
}

method cancel_subscription ($db, $reason = 'requested_by_customer') {
    return unless $stripe_subscription_id;

    my $subscription;
    try {
        $subscription = $self->stripe_client->cancel_subscription($stripe_subscription_id, {
            cancellation_details => {
                comment => $reason,
            },
        });
    }
    catch ($e) {
        die "Failed to cancel Stripe subscription: $e";
    }

    # Update schedule status
    $status = 'cancelled';
    $self->update($db, { status => $status });

    # Cancel all pending scheduled payments
    my @pending = $self->pending_payments($db);
    for my $payment (@pending) {
        $payment->update($db, { status => 'cancelled' });
    }

    return $subscription;
}

method mark_completed ($db) {
    $status = 'completed';
    $self->update($db, { status => $status });

    # Cancel subscription if it exists
    if ($stripe_subscription_id) {
        try {
            $self->stripe_client->cancel_subscription($stripe_subscription_id, {
                cancellation_details => {
                    comment => 'Payment schedule completed',
                },
            });
        }
        catch ($e) {
            # Log but don't fail if subscription cancellation fails
            warn "Failed to cancel completed subscription: $e";
        }
    }
}

method suspend ($db, $reason = 'payment_failure') {
    $status = 'suspended';
    $self->update($db, { status => $status });

    # Pause subscription if it exists
    if ($stripe_subscription_id) {
        try {
            $self->stripe_client->update_subscription($stripe_subscription_id, {
                pause_collection => {
                    behavior => 'mark_uncollectible',
                },
            });
        }
        catch ($e) {
            warn "Failed to pause subscription: $e";
        }
    }
}

method reactivate ($db) {
    die "Cannot reactivate completed schedule" if $status eq 'completed';

    $status = 'active';
    $self->update($db, { status => $status });

    # Resume subscription if it exists
    if ($stripe_subscription_id) {
        try {
            $self->stripe_client->update_subscription($stripe_subscription_id, {
                pause_collection => undef,
            });
        }
        catch ($e) {
            warn "Failed to resume subscription: $e";
        }
    }
}

sub find_by_enrollment ($class, $db, $enrollment_id) {
    return $class->find($db, { enrollment_id => $enrollment_id });
}

sub find_active ($class, $db) {
    return $class->find($db, { status => 'active' });
}

sub find_overdue ($class, $db) {
    my $today = DateTime->now->ymd;

    # Find schedules with overdue payments
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
    return [map { $class->new(%$_) } @$results];
}

}

1;