-- ABOUTME: Each location records its IANA time zone, so an occurrence's local start and date can be read.
-- ABOUTME: Added in registry and every tenant schema; existing rows get America/New_York, new rows must name one.

-- Deploy registry:location-time-zone to pg
-- requires: attendance-check-drops-schedule-next

BEGIN;

SET client_min_messages = 'warning';

-- Postgres's own zone list: AT TIME ZONE also accepts bare offsets and any
-- letter case, so the cast alone would let '+05:00' or 'america/new_york' in.
CREATE OR REPLACE FUNCTION registry.is_time_zone(zone text)
RETURNS boolean
LANGUAGE sql STABLE
AS $$ SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name = zone) $$;

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
        -- The default only fills existing rows (SACP's two are in Orlando);
        -- new rows get none, because a silent default would mis-time a class.
        EXECUTE format('ALTER TABLE %I.locations ADD COLUMN time_zone text NOT NULL DEFAULT %L', s, 'America/New_York');
        EXECUTE format('ALTER TABLE %I.locations ALTER COLUMN time_zone DROP DEFAULT', s);
        EXECUTE format('ALTER TABLE %I.locations ADD CONSTRAINT locations_time_zone_check CHECK (registry.is_time_zone(time_zone))', s);
    END LOOP;
END $$;

COMMIT;
