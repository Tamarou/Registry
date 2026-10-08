-- Verify registry:waitlist-joined-notification-type on pg

BEGIN;
SET search_path TO registry, public;

SELECT 1/COUNT(*)
FROM pg_enum e
JOIN pg_type t ON t.oid = e.enumtypid
WHERE t.typname = 'notification_type'
  AND e.enumlabel = 'waitlist_joined';

ROLLBACK;
