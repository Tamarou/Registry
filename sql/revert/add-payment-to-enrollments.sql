-- Revert registry:add-payment-to-enrollments from pg

BEGIN;

DROP INDEX IF EXISTS idx_enrollments_payment_id;
ALTER TABLE enrollments DROP COLUMN IF EXISTS payment_id;

COMMIT;