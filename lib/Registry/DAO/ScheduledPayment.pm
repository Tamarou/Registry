# ABOUTME: Individual scheduled payment tracking with Stripe integration and retry logic
# ABOUTME: Handles processing of individual installment payments with failure management
use 5.40.2;
use warnings;
use experimental 'signatures', 'try', 'builtin';

use Object::Pad;
class Registry::DAO::ScheduledPayment :isa(Registry::DAO::Object) {

use Registry::DAO::Payment;
use Registry::DAO::PaymentSchedule;
use Registry::Service::Stripe;
use DateTime;

field $id :param :reader = undef;
field $payment_schedule_id :param :reader = undef;
field $payment_id :param :reader = undef;
field $installment_number :param :reader = 0;
field $due_date :param :reader = undef;
field $amount :param :reader = 0;
field $status :param :reader = 'pending';
field $attempt_count :param :reader = 0;
field $last_attempt_at :param :reader = undef;
field $paid_at :param :reader = undef;
field $failed_at :param :reader = undef;
field $failure_reason :param :reader = undef;
field $created_at :param :reader = undef;
field $updated_at :param :reader = undef;

field $_stripe_client = undef;

sub table { 'registry.scheduled_payments' }

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

method payment_schedule ($db) {
    return Registry::DAO::PaymentSchedule->find($db, { id => $payment_schedule_id });
}

method payment ($db) {
    return unless $payment_id;
    return Registry::DAO::Payment->find($db, { id => $payment_id });
}

method process ($db, $args = {}) {
    die "Payment already processed" if $status eq 'completed';
    die "Payment is cancelled" if $status eq 'cancelled';

    # Update attempt tracking
    $attempt_count = $attempt_count + 1;
    $last_attempt_at = \'NOW()';
    $status = 'processing';
    $self->update($db, {
        attempt_count => $attempt_count,
        last_attempt_at => $last_attempt_at,
        status => $status
    });

    my $schedule = $self->payment_schedule($db);
    die "Payment schedule not found" unless $schedule;

    # Get customer payment method from the enrollment
    my $customer_id = $args->{customer_id};
    my $payment_method_id = $args->{payment_method_id};

    # If using subscription-based payment
    if ($schedule->stripe_subscription_id) {
        return $self->_process_subscription_payment($db, $schedule);
    }

    # Manual payment processing
    return $self->_process_manual_payment($db, $schedule, {
        customer_id => $customer_id,
        payment_method_id => $payment_method_id,
    });
}

method _process_subscription_payment ($db, $schedule) {
    # For subscription payments, we mostly wait for webhooks
    # This method is called when we need to manually check status

    try {
        my $subscription = $self->stripe_client->retrieve_subscription($schedule->stripe_subscription_id);

        if ($subscription->{status} eq 'active') {
            # Check for recent invoices for this installment
            my $invoices = $self->stripe_client->list_invoices({
                subscription => $schedule->stripe_subscription_id,
                limit => 10,
            });

            # Find invoice for this installment number
            for my $invoice (@{$invoices->{data}}) {
                my $metadata = $invoice->{metadata} || {};
                if ($metadata->{installment_number} &&
                    $metadata->{installment_number} == $installment_number) {

                    if ($invoice->{status} eq 'paid') {
                        return $self->_mark_completed($db, {
                            stripe_invoice_id => $invoice->{id},
                            stripe_payment_intent_id => $invoice->{payment_intent},
                        });
                    } elsif ($invoice->{status} eq 'open' && $invoice->{attempt_count} > 0) {
                        return $self->_mark_failed($db,
                            $invoice->{last_finalization_error}->{message} || 'Payment failed'
                        );
                    }
                }
            }
        }

        # If subscription is not active, mark as failed
        if ($subscription->{status} ne 'active') {
            return $self->_mark_failed($db, "Subscription status: $subscription->{status}");
        }

        # Still processing
        return { success => 0, processing => 1 };

    } catch ($e) {
        return $self->_mark_failed($db, "Subscription check failed: $e");
    }
}

method _process_manual_payment ($db, $schedule, $args) {
    die "customer_id required for manual payment" unless $args->{customer_id};
    die "payment_method_id required for manual payment" unless $args->{payment_method_id};

    # Create a Payment record for this installment
    my $payment = Registry::DAO::Payment->create($db, {
        user_id => $schedule->enrollment_id, # We'll need to get user_id from enrollment
        amount => $amount,
        currency => 'USD',
        status => 'pending',
        metadata => {
            payment_schedule_id => $payment_schedule_id,
            installment_number => $installment_number,
        },
    });

    try {
        # Create payment intent
        my $intent = $self->stripe_client->create_payment_intent({
            amount => int($amount * 100), # Convert to cents
            currency => 'usd',
            customer => $args->{customer_id},
            payment_method => $args->{payment_method_id},
            confirm => 1, # Immediately attempt payment
            description => "Installment $installment_number payment",
            metadata => {
                payment_schedule_id => $payment_schedule_id,
                scheduled_payment_id => $self->id,
                installment_number => $installment_number,
            },
        });

        # Update payment with intent ID
        $payment->update($db, {
            stripe_payment_intent_id => $intent->{id}
        });

        # Update scheduled payment with payment reference
        $payment_id = $payment->id;
        $self->update($db, { payment_id => $payment_id });

        # Process the payment result
        if ($intent->{status} eq 'succeeded') {
            $payment->update($db, {
                status => 'completed',
                completed_at => \'NOW()',
            });

            return $self->_mark_completed($db, {
                stripe_payment_intent_id => $intent->{id},
            });
        } elsif ($intent->{status} eq 'processing') {
            $payment->update($db, { status => 'processing' });
            return { success => 0, processing => 1 };
        } else {
            $payment->update($db, {
                status => 'failed',
                error_message => $intent->{last_payment_error}->{message} || 'Payment failed',
            });

            return $self->_mark_failed($db,
                $intent->{last_payment_error}->{message} || 'Payment failed'
            );
        }

    } catch ($e) {
        $payment->update($db, {
            status => 'failed',
            error_message => $e,
        });

        return $self->_mark_failed($db, "Payment processing failed: $e");
    }
}

method _mark_completed ($db, $metadata = {}) {
    $status = 'completed';
    $paid_at = \'NOW()';

    $self->update($db, {
        status => $status,
        paid_at => $paid_at,
    });

    # Check if this was the last payment in the schedule
    my $schedule = $self->payment_schedule($db);
    my @remaining = Registry::DAO::ScheduledPayment->find($db, {
        payment_schedule_id => $payment_schedule_id,
        status => 'pending',
    });

    if (@remaining == 0) {
        $schedule->mark_completed($db);
    }

    return {
        success => 1,
        scheduled_payment => $self,
        schedule_completed => @remaining == 0,
    };
}

method _mark_failed ($db, $reason) {
    $status = 'failed';
    $failed_at = \'NOW()';
    $failure_reason = $reason;

    $self->update($db, {
        status => $status,
        failed_at => $failed_at,
        failure_reason => $failure_reason,
    });

    # Check if we should suspend the schedule after too many failures
    my $schedule = $self->payment_schedule($db);
    if ($attempt_count >= 3) {
        $schedule->suspend($db, "Payment failure: $reason");
    }

    return {
        success => 0,
        error => $reason,
        attempts => $attempt_count,
        schedule_suspended => $attempt_count >= 3,
    };
}

method retry ($db, $args = {}) {
    die "Cannot retry completed payment" if $status eq 'completed';
    die "Cannot retry cancelled payment" if $status eq 'cancelled';
    die "Too many retry attempts" if $attempt_count >= 3;

    # Reset status to pending for retry
    $status = 'pending';
    $failed_at = undef;
    $failure_reason = undef;

    $self->update($db, {
        status => $status,
        failed_at => undef,
        failure_reason => undef,
    });

    # Attempt payment again
    return $self->process($db, $args);
}

method is_overdue {
    return 0 unless $status eq 'pending';
    my $today = DateTime->now->ymd;
    return $due_date lt $today;
}

method days_overdue {
    return 0 unless $self->is_overdue;

    my $due = DateTime->from_epoch(epoch => time());
    if ($due_date =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
        $due = DateTime->new(year => $1, month => $2, day => $3);
    }

    my $today = DateTime->now;
    my $duration = $today - $due;
    return $duration->in_units('days');
}

sub find_due ($class, $db, $date = undef) {
    $date ||= DateTime->now->ymd;

    return $class->find($db, {
        status => 'pending',
        due_date => { '<=' => $date }
    }, { order_by => 'due_date' });
}

sub find_overdue ($class, $db) {
    my $today = DateTime->now->ymd;

    return $class->find($db, {
        status => 'pending',
        due_date => { '<' => $today }
    }, { order_by => 'due_date' });
}

sub find_failed ($class, $db) {
    return $class->find($db, {
        status => 'failed'
    }, { order_by => { -desc => 'failed_at' } });
}

sub find_by_schedule ($class, $db, $schedule_id) {
    return $class->find($db, {
        payment_schedule_id => $schedule_id
    }, { order_by => 'installment_number' });
}

}

1;