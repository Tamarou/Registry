-- ABOUTME: Two sessions of one program may meet at one location and start: session days are unique per session and instant.
-- ABOUTME: Other events keep one per program, location and time. In registry and every tenant schema; clone_schema copies both keys.

-- Deploy registry:parallel-session-days to pg
-- requires: entitlement-requests

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
        CONTINUE WHEN to_regclass(format('%I.events', s)) IS NULL;
        EXECUTE format('ALTER TABLE %I.events DROP CONSTRAINT events_project_id_location_id_time_key', s);
        -- Named as clone_schema's LIKE ... INCLUDING ALL names its copy, so
        -- every schema's index has one name. GenerateOccurrences' ON CONFLICT
        -- names this predicate.
        EXECUTE format('CREATE UNIQUE INDEX events_project_id_location_id_time_idx ON %I.events '
                       '(project_id, location_id, time) WHERE session_resource_id IS NULL', s);
        EXECUTE format('ALTER TABLE %I.events ADD CONSTRAINT events_session_resource_id_time_key '
                       'UNIQUE (session_resource_id, time)', s);
    END LOOP;
END $$;

COMMIT;
