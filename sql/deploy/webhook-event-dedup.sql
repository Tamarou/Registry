-- Deploy registry:webhook-event-dedup to pg
-- requires: payments

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Tracks every Stripe webhook event we have accepted, keyed by Stripe's event
-- id. The unique constraint lets the webhook handler atomically claim an event
-- (INSERT ... ON CONFLICT DO NOTHING) so redelivered events are acknowledged
-- but not processed twice.
CREATE TABLE IF NOT EXISTS webhook_events (
    id              uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    stripe_event_id text NOT NULL UNIQUE,
    event_type      text,
    received_at     timestamptz NOT NULL DEFAULT now()
);

COMMIT;
