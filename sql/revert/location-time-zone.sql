-- ABOUTME: Drops the time_zone column and its guard trigger from every locations table, in registry and each tenant.
-- ABOUTME: clone_schema gave tenants provisioned since deploy their own copy of the guard function, so each goes.

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
        EXECUTE format('DROP TRIGGER IF EXISTS locations_time_zone_known ON %I.locations', s);
        EXECUTE format('ALTER TABLE %I.locations DROP COLUMN IF EXISTS time_zone', s);
    END LOOP;
    -- A second pass: a tenant provisioned before deploy has its trigger on
    -- registry's function, which may go only once every trigger has.
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        EXECUTE format('DROP FUNCTION IF EXISTS %I.locations_time_zone_known()', s);
    END LOOP;
END $$;

COMMIT;
