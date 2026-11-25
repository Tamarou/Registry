-- ABOUTME: Each location records its IANA time zone, so an occurrence's local start and date can be read.
-- ABOUTME: Added in registry and every tenant schema; existing rows get America/New_York, new rows must name one.

-- Deploy registry:location-time-zone to pg
-- requires: attendance-check-drops-schedule-next

BEGIN;

SET client_min_messages = 'warning';

-- Postgres's own zone list: AT TIME ZONE also accepts bare offsets and any
-- letter case, so the cast alone would let '+05:00' or 'america/new_york' in.
-- A trigger, not a CHECK: a restore would re-run a CHECK on every row against
-- the target server's tzdata. clone_schema copies this function and trigger
-- into each new tenant schema.
CREATE FUNCTION registry.locations_time_zone_known() RETURNS trigger AS $t$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name = NEW.time_zone) THEN
        RAISE EXCEPTION 'locations.time_zone % is not an IANA time zone name', quote_nullable(NEW.time_zone)
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$t$ LANGUAGE plpgsql;

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
        EXECUTE format('CREATE TRIGGER locations_time_zone_known BEFORE INSERT OR UPDATE OF time_zone ON %I.locations '
                       'FOR EACH ROW EXECUTE FUNCTION registry.locations_time_zone_known()', s);
    END LOOP;
END $$;

COMMIT;
