-- Revert registry:waitlist-accepted-status from pg

BEGIN;

SET search_path TO registry, public;

ALTER TABLE waitlist DROP CONSTRAINT IF EXISTS waitlist_status_check;
ALTER TABLE waitlist ADD CONSTRAINT waitlist_status_check
    CHECK (status IN ('waiting', 'offered', 'expired', 'declined'));

COMMIT;
