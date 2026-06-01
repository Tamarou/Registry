-- Revert registry:webhook-event-dedup from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

DROP TABLE IF EXISTS webhook_events CASCADE;

COMMIT;
