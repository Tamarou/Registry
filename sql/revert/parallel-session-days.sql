-- ABOUTME: Puts back one event per program, location and time in registry and every tenant schema.
-- ABOUTME: Refuses, naming the schema, while sessions of one program share a location and start.

-- Revert registry:parallel-session-days from pg

BEGIN;

SET client_min_messages = 'warning';

DO $$
DECLARE
    s        name;
    parallel boolean;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.events', s)) IS NULL;
        -- EXECUTE leaves FOUND alone, so the answer comes back INTO.
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.events GROUP BY project_id, location_id, time HAVING count(*) > 1)', s)
            INTO parallel;
        IF parallel THEN
            RAISE EXCEPTION 'cannot revert parallel-session-days: schema % has parallel session days '
                            '(sessions of one program at one location and start)', s;
        END IF;
        EXECUTE format('ALTER TABLE %I.events DROP CONSTRAINT IF EXISTS events_session_resource_id_time_key', s);
        EXECUTE format('DROP INDEX IF EXISTS %I.events_project_id_location_id_time_idx', s);
        EXECUTE format('ALTER TABLE %I.events ADD CONSTRAINT events_project_id_location_id_time_key '
                       'UNIQUE (project_id, location_id, time)', s);
    END LOOP;
END $$;

COMMIT;
