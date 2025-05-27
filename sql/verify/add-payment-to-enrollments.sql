-- Verify registry:add-payment-to-enrollments on pg

BEGIN;

SELECT payment_id FROM enrollments WHERE FALSE;

ROLLBACK;