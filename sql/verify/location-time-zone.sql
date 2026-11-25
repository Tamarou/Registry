-- ABOUTME: Verify every locations table, in registry and each tenant schema, has a NOT NULL time_zone.
-- ABOUTME: And that the zone-name check accepts a real IANA name and refuses a bare offset.

-- Verify registry:location-time-zone on pg

BEGIN;

DO $$
DECLARE
    s name;
BEGIN
    IF NOT registry.is_time_zone('America/New_York') OR registry.is_time_zone('+05:00') THEN
        RAISE EXCEPTION 'registry.is_time_zone does not match pg_timezone_names';
    END IF;
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
    END LOOP;
END $$;

ROLLBACK;
