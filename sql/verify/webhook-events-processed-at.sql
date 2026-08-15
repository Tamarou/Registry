-- Verify registry:webhook-events-processed-at on pg

BEGIN;

SET search_path TO registry, public;

SELECT processed_at FROM webhook_events WHERE FALSE;

ROLLBACK;
