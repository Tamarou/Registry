-- ABOUTME: Verify every schema's events are unique per program, location and time only outside sessions,
-- ABOUTME: and per session and instant within one.

-- Verify registry:parallel-session-days on pg

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
        CONTINUE WHEN to_regclass(format('%I.events', s)) IS NULL;
        IF to_regclass(format('%I.events_project_id_location_id_time_idx', s)) IS NULL
           OR to_regclass(format('%I.events_session_resource_id_time_key', s)) IS NULL THEN
            RAISE EXCEPTION 'schema % lacks the event slot keys', s;
        END IF;
        IF to_regclass(format('%I.events_project_id_location_id_time_key', s)) IS NOT NULL THEN
            RAISE EXCEPTION 'schema % still has one event per program, location and time', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
