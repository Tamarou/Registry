-- ABOUTME: Keep the connected account, resolved tenant and payload of a stored Stripe event.
-- ABOUTME: Refund, dispute and customer events from the Connect endpoint are stored to be applied later.

-- Deploy registry:webhook-events-connect-payload to pg
-- requires: tenant-stripe-account-unique

BEGIN;

SET client_min_messages = 'warning';

-- account is what Stripe sent; tenant_id is who it named when it arrived, NULL
-- when no tenant held that account. payload is set only for an event stored to
-- be applied later, and processed_at stays NULL until it is.
ALTER TABLE registry.webhook_events
    ADD COLUMN account text,
    ADD COLUMN tenant_id uuid REFERENCES registry.tenants (id) ON DELETE SET NULL,
    ADD COLUMN payload jsonb;

COMMIT;
