-- ABOUTME: Verify every schema's resources have a waitlist and its events link to a session resource.
-- ABOUTME: And both day-guard triggers are in place.

-- Verify registry:session-resources on pg

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
        CONTINUE WHEN to_regclass(format('%I.resources', s)) IS NULL;
        EXECUTE format('SELECT waitlist FROM %I.resources WHERE false', s);
        EXECUTE format('SELECT session_resource_id FROM %I.events WHERE false', s);
        IF (SELECT count(*) FROM pg_trigger
             WHERE tgname IN ('resources_session_day_has_no_occurrence', 'events_session_day_has_no_occurrence')
               AND tgrelid IN (format('%I.resources', s)::regclass, format('%I.events', s)::regclass)) != 2 THEN
            RAISE EXCEPTION 'schema % lacks a session day guard trigger', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
