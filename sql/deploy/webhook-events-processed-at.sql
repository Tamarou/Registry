-- Deploy registry:webhook-events-processed-at to pg
-- requires: webhook-event-dedup

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- received_at records when Stripe's delivery was claimed; processed_at records
-- when the settlement transaction committed.  The pair is the only source of
-- received-to-processed latency on the money path.
--
-- It is deliberately not a state flag.  The claim and the stamp commit or roll
-- back together, so processed_at IS NOT NULL is equivalent to the row existing;
-- a partially-processed event is not a state this table can hold.  Contrast
-- subscription_events, which pairs processed_at with processing_status and can
-- hold that state because its claim survives a failure.
ALTER TABLE webhook_events ADD COLUMN processed_at timestamptz;

COMMIT;
