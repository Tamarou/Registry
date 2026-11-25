-- ABOUTME: A hold records the lifetime it was placed with, so a charge can extend it once and no further.
-- ABOUTME: Added in registry and every tenant schema; an existing hold's lifetime is read from when it was placed.

-- Deploy registry:holds-lifetime to pg
-- requires: retire-unpublished-platform-plans

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
        -- Nullable: Hold->place writes it with the row; a hold without one is never extended.
        EXECUTE format('ALTER TABLE %I.holds ADD COLUMN IF NOT EXISTS lifetime interval', s);
        EXECUTE format('UPDATE %I.holds SET lifetime = expires_at - placed_at WHERE lifetime IS NULL', s);
    END LOOP;
END $$;

COMMIT;
