# ABOUTME: Data access object for scheduled payments table operations
# ABOUTME: Handles SQL operations for individual payment tracking and retrieval
use 5.40.2;
use warnings;
use experimental 'signatures', 'try', 'builtin';

use Object::Pad;
class Registry::DAO::ScheduledPayment :isa(Registry::DAO::Object) {

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

sub table { 'registry.scheduled_payments' }

# Simple relationship methods
method payment_schedule ($db) {
    return Registry::DAO::PaymentSchedule->find($db, { id => $payment_schedule_id });
}

method payment ($db) {
    return unless $payment_id;
    return Registry::DAO::Payment->find($db, { id => $payment_id });
}

# Class methods for common queries
sub find_due ($class, $db, $date = undef) {
    require DateTime;
    $date ||= DateTime->now->ymd;

    return $class->find($db, {
        status => 'pending',
        due_date => { '<=' => $date }
    }, { order_by => 'due_date' });
}

sub find_overdue ($class, $db) {
    require DateTime;
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