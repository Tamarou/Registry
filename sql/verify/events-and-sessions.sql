-- Verify registry:events-and-sessions on pg

BEGIN;


SET client_min_messages = 'warning';
SET search_path TO registry, public;

SELECT
    id,
    name,
    slug,
    metadata,
    notes,
    created_at
FROM locations WHERE FALSE;

SELECT
    id,
    name,
    slug,
    metadata,
    notes,
    created_at
FROM projects WHERE FALSE;

SELECT
    id,
    name,
    slug,
    metadata,
    notes,
    created_at
FROM sessions WHERE FALSE;

SELECT
    id,
    time,
    duration,
    location_id,
    project_id,
    teacher_id,
    metadata,
    notes,
    created_at
FROM events WHERE FALSE;

SELECT
    id,
    session_id,
    event_id,
    created_at
FROM session_events WHERE FALSE;

DO
$$
DECLARE
    s name;
BEGIN
   FOR s IN SELECT slug FROM registry.tenants LOOP

       EXECUTE format('SELECT id, name, slug, metadata, notes, created_at FROM %I.locations WHERE FALSE;', s);
       EXECUTE format('SELECT id, name, slug, metadata, notes, created_at FROM %I.projects WHERE FALSE;', s);
       EXECUTE format('SELECT id, name, slug, metadata, notes, created_at FROM %I.sessions WHERE FALSE;', s);
       EXECUTE format('SELECT id, time, duration, location_id, project_id, teacher_id, metadata, notes, created_at FROM %I.events WHERE FALSE;', s);
       EXECUTE format('SELECT id, session_id, event_id, created_at FROM %I.session_events WHERE FALSE;', s);

   END LOOP;
END;
$$ LANGUAGE plpgsql;

ROLLBACK;
