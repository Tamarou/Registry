-- Verify registry:restructure-data-model on pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Verify programs table exists and has correct structure
SELECT id, name, slug, metadata, notes, created_at, updated_at
FROM programs WHERE FALSE;

-- Verify curriculum table exists and has correct structure  
SELECT id, name, slug, description, metadata, notes, created_at, updated_at
FROM curriculum WHERE FALSE;

-- Verify event_curriculum junction table exists
SELECT id, event_id, curriculum_id, created_at
FROM event_curriculum WHERE FALSE;

-- Verify sessions now have program_id
SELECT id, name, slug, program_id, metadata, notes, created_at, updated_at
FROM sessions WHERE FALSE;

-- Verify events now have session_id instead of project_id
SELECT id, time, duration, location_id, session_id, teacher_id, metadata, notes, created_at, updated_at
FROM events WHERE FALSE;

-- Verify that old projects table no longer exists as a top-level table
-- This should fail if projects still exists at the top level
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables 
               WHERE table_schema = 'registry' 
               AND table_name = 'projects' 
               AND table_type = 'BASE TABLE') THEN
        RAISE EXCEPTION 'Old projects table still exists at registry level';
    END IF;
END $$;

-- Verify indexes exist
SELECT 1 FROM pg_indexes WHERE indexname = 'idx_events_session_id' AND tablename = 'events';
SELECT 1 FROM pg_indexes WHERE indexname = 'idx_sessions_program_id' AND tablename = 'sessions';
SELECT 1 FROM pg_indexes WHERE indexname = 'idx_event_curriculum_event_id' AND tablename = 'event_curriculum';
SELECT 1 FROM pg_indexes WHERE indexname = 'idx_event_curriculum_curriculum_id' AND tablename = 'event_curriculum';

-- Verify constraint exists
SELECT 1 FROM information_schema.table_constraints 
WHERE constraint_name = 'events_session_location_time_unique' 
AND table_name = 'events';

-- Verify foreign key relationships
SELECT 1 FROM information_schema.referential_constraints
WHERE constraint_name LIKE '%sessions_program_id%';

SELECT 1 FROM information_schema.referential_constraints  
WHERE constraint_name LIKE '%events_session_id%';

SELECT 1 FROM information_schema.referential_constraints
WHERE constraint_name LIKE '%event_curriculum_event_id%';

SELECT 1 FROM information_schema.referential_constraints
WHERE constraint_name LIKE '%event_curriculum_curriculum_id%';

-- Verify tenant schemas have been updated
DO
$$
DECLARE
    s name;
BEGIN
   FOR s IN SELECT slug FROM registry.tenants LOOP
       -- Verify each tenant schema has the new structure
       EXECUTE format('SELECT id, name, slug, metadata, notes, created_at, updated_at FROM %I.programs WHERE FALSE;', s);
       EXECUTE format('SELECT id, name, slug, description, metadata, notes, created_at, updated_at FROM %I.curriculum WHERE FALSE;', s);
       EXECUTE format('SELECT id, event_id, curriculum_id, created_at FROM %I.event_curriculum WHERE FALSE;', s);
       EXECUTE format('SELECT id, time, duration, location_id, session_id, teacher_id, metadata, notes, created_at, updated_at FROM %I.events WHERE FALSE;', s);
       EXECUTE format('SELECT id, name, slug, program_id, metadata, notes, created_at, updated_at FROM %I.sessions WHERE FALSE;', s);
   END LOOP;
END;
$$ LANGUAGE plpgsql;

ROLLBACK;