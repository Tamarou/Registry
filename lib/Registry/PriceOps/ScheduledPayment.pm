# ABOUTME: Business logic for scheduled payment status management via Stripe webhooks
# ABOUTME: Handles payment status updates from Stripe subscription events
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

# Business Logic: Handle Stripe webhook for invoice payment success
method handle_invoice_paid ($db, $stripe_invoice) {
    my $subscription_id = $stripe_invoice->{subscription};
    return unless $subscription_id;

    # Find payment schedule by subscription ID
    my $schedule_dao = Registry::DAO::PaymentSchedule->find($db, {
        stripe_subscription_id => $subscription_id
    });
    return unless $schedule_dao;

    # Find the corresponding scheduled payment
    # Look for pending first, then failed (for retry scenarios)
    my @outstanding_payments = Registry::DAO::ScheduledPayment->find($db, {
        payment_schedule_id => $schedule_dao->id,
        status => ['pending', 'failed']
    }, { order_by => 'installment_number' });

    # Mark the first outstanding payment as completed
    if (@outstanding_payments) {
        my $scheduled_payment = $outstanding_payments[0];
        return $self->mark_payment_completed($db, $scheduled_payment, {
            stripe_invoice_id => $stripe_invoice->{id},
            stripe_payment_intent_id => $stripe_invoice->{payment_intent},
        });
    }
}

# Business Logic: Handle Stripe webhook for invoice payment failure
method handle_invoice_payment_failed ($db, $stripe_invoice) {
    my $subscription_id = $stripe_invoice->{subscription};
    return unless $subscription_id;

    # Find payment schedule by subscription ID
    my $schedule_dao = Registry::DAO::PaymentSchedule->find($db, {
        stripe_subscription_id => $subscription_id
    });
    return unless $schedule_dao;

    # Find the corresponding scheduled payment
    my @pending_payments = Registry::DAO::ScheduledPayment->find($db, {
        payment_schedule_id => $schedule_dao->id,
        status => 'pending'
    }, { order_by => 'installment_number' });

    # Mark the first pending payment as failed
    if (@pending_payments) {
        my $scheduled_payment = $pending_payments[0];
        my $failure_reason = $stripe_invoice->{last_finalization_error}->{message} || 'Payment failed';
        return $self->mark_payment_failed($db, $scheduled_payment, $failure_reason);
    }
}

# Business Logic: Mark payment as completed and check schedule completion
method mark_payment_completed ($db, $scheduled_payment_dao, $metadata = {}) {
    # Prevent marking already completed payment, but allow retry (failed -> completed)
    die "Payment already processed" if $scheduled_payment_dao->status eq 'completed';

    # Start transaction for atomic operation
    my $tx = $db->begin;
    my $schedule_completed = 0;

    try {
        # Mark this payment as completed
        $scheduled_payment_dao->update($db, {
            status => 'completed',
            paid_at => \'NOW()',
        });

        # Lock the payment schedule row to prevent concurrent completion
        my $schedule_result = $db->query(
            'SELECT * FROM registry.payment_schedules WHERE id = ? FOR UPDATE',
            $scheduled_payment_dao->payment_schedule_id
        )->hash;

        # Verify schedule exists and is not already completed
        if (!$schedule_result) {
            die "Payment schedule not found: " . $scheduled_payment_dao->payment_schedule_id;
        }

        if ($schedule_result->{status} eq 'completed') {
            # Schedule already completed by another process, just return success
            $tx->commit;
            return {
                success => 1,
                scheduled_payment => $scheduled_payment_dao,
                schedule_completed => 0,  # Already was completed
            };
        }

        # Count remaining pending payments (within the same transaction)
        my $remaining_count = $db->query(
            'SELECT COUNT(*) FROM registry.scheduled_payments WHERE payment_schedule_id = ? AND status = ?',
            $scheduled_payment_dao->payment_schedule_id,
            'pending'
        )->hash->{count};

        # If no remaining payments, mark schedule as completed
        if ($remaining_count == 0) {
            # Update schedule status atomically
            $db->query(
                'UPDATE registry.payment_schedules SET status = ?, updated_at = NOW() WHERE id = ? AND status != ?',
                'completed',
                $scheduled_payment_dao->payment_schedule_id,
                'completed'
            );

            # Cancel Stripe subscription if exists
            if ($schedule_result->{stripe_subscription_id}) {
                try {
                    $stripe_client->cancel_subscription_with_reason(
                        $schedule_result->{stripe_subscription_id},
                        'Payment schedule completed'
                    );
                }
                catch ($e) {
                    # Log but don't fail if subscription cancellation fails
                    warn "Failed to cancel completed subscription: $e";
                }
            }

            $schedule_completed = 1;
        }

        # Commit the transaction
        $tx->commit;
    }
    catch ($e) {
        # Transaction will automatically rollback on error
        die "Failed to mark payment completed: $e";
    }

    return {
        success => 1,
        scheduled_payment => $scheduled_payment_dao,
        schedule_completed => $schedule_completed,
    };
}

# Business Logic: Mark payment as failed (Stripe Smart Retries handles retry logic)
method mark_payment_failed ($db, $scheduled_payment_dao, $reason) {
    $scheduled_payment_dao->update($db, {
        status => 'failed',
        failed_at => \'NOW()',
        failure_reason => $reason,
    });

    # Let Stripe handle subscription suspension via dunning management
    # We just update local status based on subscription events

    return {
        success => 1,  # Webhook processed successfully
        reason => $reason,
    };
}

}

1;