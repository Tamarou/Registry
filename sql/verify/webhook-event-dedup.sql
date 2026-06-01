-- Verify registry:webhook-event-dedup on pg

BEGIN;

SET search_path TO registry, public;

SELECT id, stripe_event_id, event_type, received_at
  FROM webhook_events WHERE FALSE;

ROLLBACK;
