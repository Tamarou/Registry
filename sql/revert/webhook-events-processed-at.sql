-- Revert registry:webhook-events-processed-at from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- No IF EXISTS: this change created the column, so a missing column means the
-- database is not in the state the revert was written for.  Aborting is the
-- correct outcome; a silent skip would leave the round-trip harness green.
ALTER TABLE webhook_events DROP COLUMN processed_at;

COMMIT;
