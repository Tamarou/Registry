-- Revert registry:restructure-data-model from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Step 1: Revert all tenant schemas first
DO
$$
DECLARE
    s name;
BEGIN
   FOR s IN SELECT slug FROM registry.tenants LOOP
       -- Only process if schema exists
       IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = s) THEN
           -- Drop new tables
           EXECUTE format('DROP TABLE IF EXISTS "%s".event_curriculum;', s);
           EXECUTE format('DROP TABLE IF EXISTS "%s".curriculum;', s);
           EXECUTE format('DROP TABLE IF EXISTS "%s".programs;', s);

           -- Recreate original projects table
           EXECUTE format('CREATE TABLE IF NOT EXISTS "%s".projects (
           id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
           name text UNIQUE NOT NULL,
           slug text UNIQUE NOT NULL,
           metadata jsonb NULL,
           notes text NULL,
           created_at timestamp with time zone DEFAULT now(),
           updated_at timestamp NOT NULL DEFAULT current_timestamp
       );', s);
       
       -- Remove session_id from events and add back project_id
       EXECUTE format('ALTER TABLE "%s".events DROP COLUMN IF EXISTS session_id;', s);
       EXECUTE format('ALTER TABLE "%s".events ADD COLUMN project_id uuid REFERENCES "%s".projects(id);', s, s);

       -- Remove program_id from sessions
       EXECUTE format('ALTER TABLE "%s".sessions DROP COLUMN IF EXISTS program_id;', s);
       
       -- Restore original constraints and indexes
       EXECUTE format('ALTER TABLE "%s".events DROP CONSTRAINT IF EXISTS events_session_location_time_unique;', s);
       EXECUTE format('ALTER TABLE "%s".events ADD CONSTRAINT events_project_id_location_id_time_key
           UNIQUE (project_id, location_id, time);', s);
       
       -- Restore original indexes
       EXECUTE format('DROP INDEX IF EXISTS "%s".idx_events_session_id;', s);
       EXECUTE format('DROP INDEX IF EXISTS "%s".idx_sessions_program_id;', s);
       EXECUTE format('DROP INDEX IF EXISTS "%s".idx_event_curriculum_event_id;', s);
       EXECUTE format('DROP INDEX IF EXISTS "%s".idx_event_curriculum_curriculum_id;', s);
       EXECUTE format('CREATE INDEX IF NOT EXISTS idx_events_project_id ON "%s".events(project_id);', s);
       END IF; -- end schema exists check
   END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Step 2: Revert main registry schema
-- Drop new tables
DROP TABLE IF EXISTS event_curriculum;
DROP TABLE IF EXISTS curriculum;
DROP TABLE IF EXISTS programs;

-- Recreate original projects table
CREATE TABLE IF NOT EXISTS projects (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    name text UNIQUE NOT NULL,
    slug text UNIQUE NOT NULL,
    metadata jsonb NULL,
    notes text NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp NOT NULL DEFAULT current_timestamp
);

-- Remove session_id from events and add back project_id
ALTER TABLE events DROP COLUMN IF EXISTS session_id;
ALTER TABLE events ADD COLUMN project_id uuid NOT NULL REFERENCES projects(id);

-- Remove program_id from sessions
ALTER TABLE sessions DROP COLUMN IF EXISTS program_id;

-- Restore original constraints
ALTER TABLE events DROP CONSTRAINT IF EXISTS events_session_location_time_unique;
ALTER TABLE events ADD CONSTRAINT events_project_id_location_id_time_key 
    UNIQUE (project_id, location_id, time);

-- Restore original indexes
DROP INDEX IF EXISTS idx_events_session_id;
DROP INDEX IF EXISTS idx_sessions_program_id;
DROP INDEX IF EXISTS idx_event_curriculum_event_id;
DROP INDEX IF EXISTS idx_event_curriculum_curriculum_id;
CREATE INDEX IF NOT EXISTS idx_events_project_id ON events(project_id);

COMMIT;