-- Verify registry:add-payment-to-enrollments on pg

BEGIN;

SET search_path TO registry, public;

SELECT payment_id FROM enrollments WHERE FALSE;

ROLLBACK;