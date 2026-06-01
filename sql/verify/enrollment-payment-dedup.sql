-- Verify registry:enrollment-payment-dedup on pg

BEGIN;

SET search_path TO registry, public;

SELECT 1 / count(*)
  FROM pg_indexes
 WHERE schemaname = 'registry'
   AND tablename = 'enrollments'
   AND indexname = 'enrollments_payment_dedup';

ROLLBACK;
