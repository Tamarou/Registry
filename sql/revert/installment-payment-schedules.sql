-- Revert registry:installment-payment-schedules from pg

BEGIN;

SET search_path TO registry, public;

-- Drop tables in reverse order
DROP TABLE IF EXISTS registry.scheduled_payments;
DROP TABLE IF EXISTS registry.payment_schedules;

COMMIT;
