-- ABOUTME: Drop the placed_at stamp from holds in registry and every tenant schema.
-- ABOUTME: Only the change-fee charge reads it, to extend a hold by its own length.

-- Revert registry:holds-placed-at from pg

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
        EXECUTE format('ALTER TABLE %I.holds DROP COLUMN IF EXISTS placed_at', s);
    END LOOP;
END $$;

COMMIT;
