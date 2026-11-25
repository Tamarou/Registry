-- ABOUTME: Drop the roles and public mark from workflows in registry and every tenant schema.
-- ABOUTME: Registry.pm's map still guards every slug, so nothing loses its guard.

-- Revert registry:workflow-roles-data from pg

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
        EXECUTE format('ALTER TABLE %I.workflows DROP COLUMN IF EXISTS roles', s);
        EXECUTE format('ALTER TABLE %I.workflows DROP COLUMN IF EXISTS public', s);
    END LOOP;
END $$;

COMMIT;
