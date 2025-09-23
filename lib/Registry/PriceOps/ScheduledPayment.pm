# ABOUTME: Business logic for individual scheduled payment processing and retry management
# ABOUTME: Handles payment attempt logic, failure handling, and Stripe integration
use 5.40.2;
use warnings;
use experimental 'signatures', 'try', 'builtin';

use Object::Pad;
class Registry::PriceOps::ScheduledPayment {

use Registry::DAO::ScheduledPayment;
use Registry::DAO::Payment;
use Registry::Client::Stripe;
use DateTime;

field $stripe_client :param = undef;

ADJUST {
    $stripe_client //= Registry::Client::Stripe->new;
}

# Business Logic: Process payment with retry logic and failure handling
method process_payment ($db, $scheduled_payment_dao, $args = {}) {
    die "Payment already processed" if $scheduled_payment_dao->status eq 'completed';
    die "Payment is cancelled" if $scheduled_payment_dao->status eq 'cancelled';

    # Business rule: Increment attempt count and update status
    my $new_attempt_count = $scheduled_payment_dao->attempt_count + 1;
    $scheduled_payment_dao->update($db, {
        attempt_count => $new_attempt_count,
        last_attempt_at => \'NOW()',
        status => 'processing'
    });

    # Get payment schedule for context
    my $schedule_dao = Registry::DAO::PaymentSchedule->find($db, {
        id => $scheduled_payment_dao->payment_schedule_id
    });
    die "Payment schedule not found" unless $schedule_dao;

    # Choose processing method based on schedule configuration
    if ($schedule_dao->stripe_subscription_id) {
        return $self->process_subscription_payment($db, $scheduled_payment_dao, $schedule_dao);
    } else {
        return $self->process_manual_payment($db, $scheduled_payment_dao, $schedule_dao, $args);
    }
}

# Business Logic: Process subscription-based payment
method process_subscription_payment ($db, $scheduled_payment_dao, $schedule_dao) {
    try {
        my $subscription = $stripe_client->retrieve_subscription($schedule_dao->stripe_subscription_id);

        if ($subscription->{status} eq 'active') {
            # Check for invoices for this installment
            my $invoices = $stripe_client->list_invoices({
                subscription => $schedule_dao->stripe_subscription_id,
                limit => 10,
            });

            # Find matching invoice for this installment
            for my $invoice (@{$invoices->{data}}) {
                my $metadata = $invoice->{metadata} || {};
                if ($metadata->{installment_number} &&
                    $metadata->{installment_number} == $scheduled_payment_dao->installment_number) {

                    if ($invoice->{status} eq 'paid') {
                        return $self->mark_payment_completed($db, $scheduled_payment_dao, {
                            stripe_invoice_id => $invoice->{id},
                            stripe_payment_intent_id => $invoice->{payment_intent},
                        });
                    } elsif ($invoice->{status} eq 'open' && $invoice->{attempt_count} > 0) {
                        return $self->mark_payment_failed($db, $scheduled_payment_dao,
                            $invoice->{last_finalization_error}->{message} || 'Payment failed'
                        );
                    }
                }
            }
        }

        # If subscription is not active, mark as failed
        if ($subscription->{status} ne 'active') {
            return $self->mark_payment_failed($db, $scheduled_payment_dao,
                "Subscription status: $subscription->{status}");
        }

        # Still processing
        return { success => 0, processing => 1 };

    } catch ($e) {
        return $self->mark_payment_failed($db, $scheduled_payment_dao,
            "Subscription check failed: $e");
    }
}

# Business Logic: Process manual payment via PaymentIntent
method process_manual_payment ($db, $scheduled_payment_dao, $schedule_dao, $args) {
    my $customer_id = $args->{customer_id} || die "customer_id required for manual payment";
    my $payment_method_id = $args->{payment_method_id} || die "payment_method_id required";

    # Create Payment record for this installment
    my $payment_dao = Registry::DAO::Payment->create($db, {
        user_id => $schedule_dao->enrollment_id, # TODO: Get actual user_id from enrollment
        amount => $scheduled_payment_dao->amount,
        currency => 'USD',
        status => 'pending',
        metadata => {
            payment_schedule_id => $scheduled_payment_dao->payment_schedule_id,
            installment_number => $scheduled_payment_dao->installment_number,
        },
    });

    try {
        # Create and confirm payment intent
        my $intent = $stripe_client->create_installment_payment_intent({
            customer_id => $customer_id,
            payment_method_id => $payment_method_id,
            amount_cents => int($scheduled_payment_dao->amount * 100),
            description => "Installment " . $scheduled_payment_dao->installment_number . " payment",
            metadata => {
                payment_schedule_id => $scheduled_payment_dao->payment_schedule_id,
                scheduled_payment_id => $scheduled_payment_dao->id,
                installment_number => $scheduled_payment_dao->installment_number,
            },
        });

        # Update payment with intent ID
        $payment_dao->update($db, {
            stripe_payment_intent_id => $intent->{id}
        });

        # Link scheduled payment to payment record
        $scheduled_payment_dao->update($db, { payment_id => $payment_dao->id });

        # Process payment result
        if ($intent->{status} eq 'succeeded') {
            $payment_dao->update($db, {
                status => 'completed',
                completed_at => \'NOW()',
            });

            return $self->mark_payment_completed($db, $scheduled_payment_dao, {
                stripe_payment_intent_id => $intent->{id},
            });
        } elsif ($intent->{status} eq 'processing') {
            $payment_dao->update($db, { status => 'processing' });
            return { success => 0, processing => 1 };
        } else {
            $payment_dao->update($db, {
                status => 'failed',
                error_message => $intent->{last_payment_error}->{message} || 'Payment failed',
            });

            return $self->mark_payment_failed($db, $scheduled_payment_dao,
                $intent->{last_payment_error}->{message} || 'Payment failed'
            );
        }

    } catch ($e) {
        $payment_dao->update($db, {
            status => 'failed',
            error_message => $e,
        });

        return $self->mark_payment_failed($db, $scheduled_payment_dao,
            "Payment processing failed: $e");
    }
}

# Business Logic: Mark payment as completed and check schedule completion
method mark_payment_completed ($db, $scheduled_payment_dao, $metadata = {}) {
    $scheduled_payment_dao->update($db, {
        status => 'completed',
        paid_at => \'NOW()',
    });

    # Business rule: Check if this completes the entire schedule
    my @remaining = Registry::DAO::ScheduledPayment->find($db, {
        payment_schedule_id => $scheduled_payment_dao->payment_schedule_id,
        status => 'pending',
    });

    my $schedule_completed = @remaining == 0;
    if ($schedule_completed) {
        # Mark the entire schedule as completed
        my $schedule_dao = Registry::DAO::PaymentSchedule->find($db, {
            id => $scheduled_payment_dao->payment_schedule_id
        });

        my $schedule_ops = Registry::PriceOps::PaymentSchedule->new(
            stripe_client => $stripe_client
        );
        $schedule_ops->mark_completed($db, $schedule_dao);
    }

    return {
        success => 1,
        scheduled_payment => $scheduled_payment_dao,
        schedule_completed => $schedule_completed,
    };
}

# Business Logic: Mark payment as failed and handle schedule suspension
method mark_payment_failed ($db, $scheduled_payment_dao, $reason) {
    $scheduled_payment_dao->update($db, {
        status => 'failed',
        failed_at => \'NOW()',
        failure_reason => $reason,
    });

    # Business rule: Suspend schedule after too many failures
    my $schedule_suspended = 0;
    if ($scheduled_payment_dao->attempt_count >= 3) {
        my $schedule_dao = Registry::DAO::PaymentSchedule->find($db, {
            id => $scheduled_payment_dao->payment_schedule_id
        });

        my $schedule_ops = Registry::PriceOps::PaymentSchedule->new(
            stripe_client => $stripe_client
        );
        $schedule_ops->suspend($db, $schedule_dao, "Payment failure: $reason");
        $schedule_suspended = 1;
    }

    return {
        success => 0,
        error => $reason,
        attempts => $scheduled_payment_dao->attempt_count,
        schedule_suspended => $schedule_suspended,
    };
}

# Business Logic: Retry failed payment with validation
method retry_payment ($db, $scheduled_payment_dao, $args = {}) {
    die "Cannot retry completed payment" if $scheduled_payment_dao->status eq 'completed';
    die "Cannot retry cancelled payment" if $scheduled_payment_dao->status eq 'cancelled';
    die "Too many retry attempts" if $scheduled_payment_dao->attempt_count >= 3;

    # Business rule: Reset payment status for retry
    $scheduled_payment_dao->update($db, {
        status => 'pending',
        failed_at => undef,
        failure_reason => undef,
    });

    # Attempt payment again
    return $self->process_payment($db, $scheduled_payment_dao, $args);
}

# Business Logic: Check if payment is overdue
method is_payment_overdue ($scheduled_payment_dao) {
    return 0 unless $scheduled_payment_dao->status eq 'pending';
    my $today = DateTime->now->ymd;
    return $scheduled_payment_dao->due_date lt $today;
}

# Business Logic: Calculate days overdue
method calculate_days_overdue ($scheduled_payment_dao) {
    return 0 unless $self->is_payment_overdue($scheduled_payment_dao);

    my $due_date = $scheduled_payment_dao->due_date;
    my $due = DateTime->now;

    if ($due_date =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
        $due = DateTime->new(year => $1, month => $2, day => $3);
    }

    my $today = DateTime->now;
    my $duration = $today - $due;
    return $duration->in_units('days');
}

}

1;