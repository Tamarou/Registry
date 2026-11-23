-- ABOUTME: Verify registry.webhook_events keeps the account, tenant and payload of an event.
-- ABOUTME: Fails if any of the three columns is missing.

-- Verify registry:webhook-events-connect-payload on pg

BEGIN;

SELECT account, tenant_id, payload FROM registry.webhook_events WHERE false;

ROLLBACK;
