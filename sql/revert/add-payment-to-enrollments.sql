-- Revert registry:add-payment-to-enrollments from pg

BEGIN;

SET search_path TO registry, public;

DROP INDEX IF EXISTS idx_enrollments_payment_id;
ALTER TABLE enrollments DROP COLUMN IF EXISTS payment_id;

COMMIT;