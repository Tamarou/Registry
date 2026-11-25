-- ABOUTME: Drops the time_zone column from every locations table, in registry and each tenant schema.
-- ABOUTME: Then drops the zone-name check function the column's constraint used.

-- Revert registry:location-time-zone from pg

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
        CONTINUE WHEN to_regclass(format('%I.locations', s)) IS NULL;
        EXECUTE format('ALTER TABLE %I.locations DROP COLUMN IF EXISTS time_zone', s);
    END LOOP;
END $$;

DROP FUNCTION IF EXISTS registry.is_time_zone(text);

COMMIT;
