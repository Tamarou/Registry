-- ABOUTME: Drops sessions' link from events to their resource, the waitlist column and the day guard.
-- ABOUTME: In registry and each tenant; clone_schema gave tenants provisioned since deploy their own guard function.

-- Revert registry:session-resources from pg

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
        CONTINUE WHEN to_regclass(format('%I.resources', s)) IS NULL;
        EXECUTE format('DROP TRIGGER IF EXISTS resources_session_day_has_no_occurrence ON %I.resources', s);
        EXECUTE format('DROP TRIGGER IF EXISTS events_session_day_has_no_occurrence ON %I.events', s);
        EXECUTE format('ALTER TABLE %I.events DROP COLUMN IF EXISTS session_resource_id', s);
        EXECUTE format('ALTER TABLE %I.resources DROP COLUMN IF EXISTS waitlist', s);
    END LOOP;
    -- Second pass: tenants made before deploy trigger on registry's function.
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        EXECUTE format('DROP FUNCTION IF EXISTS %I.session_day_has_no_occurrence()', s);
    END LOOP;
END $$;

COMMIT;
