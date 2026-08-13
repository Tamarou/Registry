-- ABOUTME: Superseded verify for the installment schema reshape.
-- ABOUTME: Both reshaped tables are dropped by drop-installment-schedules.

-- Verify registry:simplify-installment-schema-for-stripe on pg

BEGIN;

-- This change only reshaped payment_schedules and scheduled_payments, both
-- dropped by drop-installment-schedules.  See that change's verify.

ROLLBACK;
