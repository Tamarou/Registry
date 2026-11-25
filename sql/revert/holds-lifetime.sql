-- ABOUTME: Drop the lifetime from holds in registry and every tenant schema.
-- ABOUTME: Only the change-fee charge reads it, to bound how far a hold is extended.

-- Revert registry:holds-lifetime from pg

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
        CONTINUE WHEN to_regclass(format('%I.holds', s)) IS NULL;
        EXECUTE format('ALTER TABLE %I.holds DROP COLUMN IF EXISTS lifetime', s);
    END LOOP;
END $$;

COMMIT;
