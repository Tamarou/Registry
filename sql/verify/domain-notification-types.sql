-- Verify registry:domain-notification-types on pg

BEGIN;
SET search_path TO registry, public;

SELECT 1/count(*)
FROM pg_enum e
JOIN pg_type t ON t.oid = e.enumtypid
WHERE t.typname = 'notification_type'
  AND e.enumlabel IN ('domain_verified', 'domain_verification_failed')
HAVING count(*) = 2;

ROLLBACK;
