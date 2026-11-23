-- ABOUTME: Drop the interim tenant-holds-resource table, and with it the seeded operator right.
-- ABOUTME: Tenant schemas cloned since keep their empty copies; nothing reads those.

-- Revert registry:operator-right from pg

BEGIN;

SET client_min_messages = 'warning';

DROP TABLE IF EXISTS registry.tenant_resources;

COMMIT;
