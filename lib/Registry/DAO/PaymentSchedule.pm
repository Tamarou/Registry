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
field $first_payment_date :param :reader = undef;
field $frequency :param :reader = 'monthly';
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

}

1;