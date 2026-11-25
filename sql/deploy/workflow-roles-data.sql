-- ABOUTME: Who may run a workflow becomes data on its row: a list of roles, or the public mark.
-- ABOUTME: Added in registry and every tenant schema; nothing reads it yet, the gate still reads Registry.pm's map.

-- Deploy registry:workflow-roles-data to pg
-- requires: drop-tenant-billing-columns

BEGIN;

SET client_min_messages = 'warning';

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.workflows', s)) IS NULL;
        -- NULL roles and public false is "no entry": the next step's gate refuses it.
        EXECUTE format('ALTER TABLE %I.workflows ADD COLUMN IF NOT EXISTS roles text[]', s);
        EXECUTE format('ALTER TABLE %I.workflows ADD COLUMN IF NOT EXISTS public boolean NOT NULL DEFAULT false', s);
    END LOOP;
END $$;

COMMIT;
