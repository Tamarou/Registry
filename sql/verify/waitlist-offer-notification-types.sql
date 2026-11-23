-- ABOUTME: Verify notification_type holds both waitlist_offer and waitlist_expiration.
-- ABOUTME: Divides by zero, failing the verify, when either is missing.

-- Verify registry:waitlist-offer-notification-types on pg

BEGIN;
SET search_path TO registry, public;

SELECT 1/(COUNT(*) - 1)
FROM pg_enum e
JOIN pg_type t ON t.oid = e.enumtypid
WHERE t.typname = 'notification_type'
  AND e.enumlabel IN ('waitlist_offer', 'waitlist_expiration');

ROLLBACK;
