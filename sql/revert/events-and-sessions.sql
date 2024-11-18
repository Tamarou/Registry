-- Revert registry:events-and-sessions from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

DO
$$
DECLARE
    s name;
BEGIN
   FOR s IN SELECT slug FROM registry.tenants LOOP
       EXECUTE format('DROP TABLE IF EXISTS %I.session_events;', s);
       EXECUTE format('DROP TABLE IF EXISTS %I.events;', s);
       EXECUTE format('DROP TABLE IF EXISTS %I.sessions;', s);
       EXECUTE format('DROP TABLE IF EXISTS %I.projects;', s);
       EXECUTE format('DROP TABLE IF EXISTS %I.locations;', s);
   END LOOP;
END;
$$ LANGUAGE plpgsql;

DROP TABLE IF EXISTS session_events;
DROP TABLE IF EXISTS events;
DROP TABLE IF EXISTS sessions;
DROP TABLE IF EXISTS projects;
DROP TABLE IF EXISTS locations;

COMMIT;
