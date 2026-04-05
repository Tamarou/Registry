-- ABOUTME: Add 'accepted' to the waitlist status check constraint.
-- ABOUTME: Allows distinguishing accepted offers from declined ones.

-- Deploy registry:waitlist-accepted-status to pg

BEGIN;

SET search_path TO registry, public;

ALTER TABLE waitlist DROP CONSTRAINT IF EXISTS waitlist_status_check;
ALTER TABLE waitlist ADD CONSTRAINT waitlist_status_check
    CHECK (status IN ('waiting', 'offered', 'accepted', 'expired', 'declined'));

COMMIT;
