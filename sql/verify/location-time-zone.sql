-- ABOUTME: Verify every locations table, in registry and each tenant schema, has a NOT NULL time_zone.
-- ABOUTME: And the trigger that refuses a name missing from pg_timezone_names.

-- Verify registry:location-time-zone on pg

BEGIN;

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
        IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                        WHERE table_schema = s AND table_name = 'locations'
                          AND column_name = 'time_zone' AND is_nullable = 'NO') THEN
            RAISE EXCEPTION 'schema % has no NOT NULL locations.time_zone', s;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_trigger
                        WHERE tgrelid = format('%I.locations', s)::regclass
                          AND tgname = 'locations_time_zone_known') THEN
            RAISE EXCEPTION 'schema % has no locations_time_zone_known trigger', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
