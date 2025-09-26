-- Verify registry:installment-payment-schedules on pg

BEGIN;

SET search_path TO registry, public;

-- Verify payment_schedules table exists with correct structure
SELECT id, enrollment_id, pricing_plan_id, stripe_subscription_id, total_amount,
       installment_amount, installment_count, first_payment_date, frequency,
       status, created_at, updated_at
FROM registry.payment_schedules
WHERE FALSE;

-- Verify scheduled_payments table exists with correct structure
SELECT id, payment_schedule_id, payment_id, installment_number, due_date,
       amount, status, attempt_count, last_attempt_at, paid_at, failed_at,
       failure_reason, created_at, updated_at
FROM registry.scheduled_payments
WHERE FALSE;

-- Verify indexes exist
SELECT 1/count(*) FROM pg_class WHERE relname = 'idx_payment_schedules_enrollment';
SELECT 1/count(*) FROM pg_class WHERE relname = 'idx_scheduled_payments_schedule';

ROLLBACK;
