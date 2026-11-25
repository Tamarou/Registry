-- ABOUTME: A hold records when it was placed, so a charge can extend it by its own length.
-- ABOUTME: Added in registry and every tenant schema; an existing hold counts as placed when this runs.

-- Deploy registry:holds-placed-at to pg
-- requires: entitlement-uses

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
        -- The clock, as Hold->place compares expires_at to it.
        EXECUTE format(
            'ALTER TABLE %I.holds ADD COLUMN IF NOT EXISTS placed_at timestamp with time zone
                 NOT NULL DEFAULT clock_timestamp()', s);
    END LOOP;
END $$;

COMMIT;
