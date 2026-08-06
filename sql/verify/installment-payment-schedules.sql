-- Verify registry:installment-payment-schedules on pg

BEGIN;

SET search_path TO registry, public;

-- Verify payment_schedules table exists with correct structure. The money
-- columns are deliberately absent: a later change renames them, so asserting
-- them here would fail once that change deploys.
SELECT id, enrollment_id, pricing_plan_id, stripe_subscription_id,
       installment_count,
       status, created_at, updated_at
FROM registry.payment_schedules
WHERE FALSE;

-- Verify scheduled_payments table exists with correct structure. The money
-- column is deliberately absent for the same reason.
SELECT id, payment_schedule_id, payment_id, installment_number,
       status, paid_at, failed_at,
       failure_reason, created_at, updated_at
FROM registry.scheduled_payments
WHERE FALSE;

-- Verify indexes exist
SELECT 1/count(*) FROM pg_class WHERE relname = 'idx_payment_schedules_enrollment';
SELECT 1/count(*) FROM pg_class WHERE relname = 'idx_scheduled_payments_schedule';

ROLLBACK;
