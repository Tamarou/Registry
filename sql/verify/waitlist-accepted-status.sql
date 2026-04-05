-- Verify registry:waitlist-accepted-status on pg

BEGIN;

SET search_path TO registry, public;

SELECT 1 FROM pg_constraint
WHERE conname = 'waitlist_status_check'
  AND pg_get_constraintdef(oid) LIKE '%accepted%';

ROLLBACK;
