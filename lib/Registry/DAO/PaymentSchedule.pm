# ABOUTME: Data access object for payment schedules table operations
# ABOUTME: Handles SQL operations for payment schedule persistence and retrieval
use 5.40.2;
use warnings;
use experimental 'signatures', 'try', 'builtin';

use Object::Pad;
class Registry::DAO::PaymentSchedule :isa(Registry::DAO::Object) {

field $id :param :reader = undef;
field $enrollment_id :param :reader = undef;
field $pricing_plan_id :param :reader = undef;
field $stripe_subscription_id :param :reader = undef;
field $total_amount :param :reader = 0;
field $installment_amount :param :reader = 0;
field $installment_count :param :reader = 0;
field $status :param :reader = 'active';
field $created_at :param :reader = undef;
field $updated_at :param :reader = undef;

sub table { 'registry.payment_schedules' }

# Simple query methods for relationships
method scheduled_payments ($db) {
    return Registry::DAO::ScheduledPayment->find($db,
        { payment_schedule_id => $self->id },
        { order_by => 'installment_number' }
    );
}

# Class methods for common queries
sub find_by_enrollment ($class, $db, $enrollment_id) {
    return $class->find($db, { enrollment_id => $enrollment_id });
}

sub find_active ($class, $db) {
    return $class->find($db, { status => 'active' });
}

sub find_by_stripe_subscription_id ($class, $db, $subscription_id) {
    my $results = $class->find($db, { stripe_subscription_id => $subscription_id });
    return $results || [];
}

# Instance methods for status management
method update_status ($db, $new_status) {
    return unless $new_status ne $self->status;

    $db->update($self->table,
        { status => $new_status, updated_at => \'NOW()' },
        { id => $self->id }
    );

    # Update the object field
    $status = $new_status;
    return $self;
}

method cancel_with_pending_payments ($db) {
    # Start transaction to ensure atomicity
    my $tx = $db->begin;

    try {
        # Update schedule status
        $self->update_status($db, 'cancelled');

        # Cancel all pending scheduled payments
        $db->update('registry.scheduled_payments',
            { status => 'cancelled', updated_at => \'NOW()' },
            { payment_schedule_id => $self->id, status => 'pending' }
        );

        $tx->commit;
    } catch ($e) {
        $tx->rollback;
        die "Failed to cancel payment schedule: $e";
    }

    return $self;
}

}

1;