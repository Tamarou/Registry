-- ABOUTME: Drop the account, tenant and payload columns from registry.webhook_events.
-- ABOUTME: Stored Connect events then lose what a later step needs to apply them.

-- Revert registry:webhook-events-connect-payload from pg

BEGIN;

ALTER TABLE registry.webhook_events
    DROP COLUMN IF EXISTS payload,
    DROP COLUMN IF EXISTS tenant_id,
    DROP COLUMN IF EXISTS account;

COMMIT;
