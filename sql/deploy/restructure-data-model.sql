-- Deploy registry:restructure-data-model-simple to pg
-- requires: summer-camp-module

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Simple approach: Just restructure the schema without preserving data
-- This is appropriate for development environments

-- Step 1: Create programs table (rename of current projects concept)
CREATE TABLE IF NOT EXISTS programs (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    name text UNIQUE NOT NULL,
    slug text UNIQUE NOT NULL,
    description text NULL,
    metadata jsonb NULL,
    notes text NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp NOT NULL DEFAULT current_timestamp
);

-- Step 2: Add program_id to sessions table
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS program_id uuid REFERENCES programs(id);

-- Step 3: Add session_id to events table 
ALTER TABLE events ADD COLUMN IF NOT EXISTS session_id uuid REFERENCES sessions(id);

-- Step 4: Drop old project_id from events (if it exists)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns 
               WHERE table_schema = 'registry' AND table_name = 'events' AND column_name = 'project_id') THEN
        ALTER TABLE events DROP COLUMN project_id;
    END IF;
END $$;

-- Step 5: Drop old projects table and create new curriculum table
DROP TABLE IF EXISTS projects CASCADE;

CREATE TABLE IF NOT EXISTS curriculum (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    name text NOT NULL,
    slug text NOT NULL,
    description text,
    metadata jsonb NULL,
    notes text NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp NOT NULL DEFAULT current_timestamp,
    UNIQUE(slug) -- curriculum can be reused across events
);

-- Step 6: Create event_curriculum junction table for many-to-many
CREATE TABLE IF NOT EXISTS event_curriculum (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    event_id uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    curriculum_id uuid NOT NULL REFERENCES curriculum(id) ON DELETE CASCADE,
    created_at timestamp with time zone DEFAULT now(),
    UNIQUE(event_id, curriculum_id)
);

-- Step 7: Update constraints on events
DO $$
BEGIN
    -- Drop old constraint if it exists
    IF EXISTS (SELECT 1 FROM information_schema.table_constraints 
               WHERE constraint_name = 'events_project_id_location_id_time_key' 
               AND table_name = 'events' AND table_schema = 'registry') THEN
        ALTER TABLE events DROP CONSTRAINT events_project_id_location_id_time_key;
    END IF;
    
    -- Add new constraint if it doesn't exist
    IF NOT EXISTS (SELECT 1 FROM information_schema.table_constraints 
                   WHERE constraint_name = 'events_session_location_time_unique' 
                   AND table_name = 'events' AND table_schema = 'registry') THEN
        ALTER TABLE events ADD CONSTRAINT events_session_location_time_unique 
            UNIQUE (session_id, location_id, time);
    END IF;
END $$;

-- Step 8: Update indexes
DROP INDEX IF EXISTS idx_events_project_id;
CREATE INDEX IF NOT EXISTS idx_events_session_id ON events(session_id);
CREATE INDEX IF NOT EXISTS idx_sessions_program_id ON sessions(program_id);
CREATE INDEX IF NOT EXISTS idx_event_curriculum_event_id ON event_curriculum(event_id);
CREATE INDEX IF NOT EXISTS idx_event_curriculum_curriculum_id ON event_curriculum(curriculum_id);

-- Step 9: Apply changes to all tenant schemas
DO
$$
DECLARE
    s name;
    tenants_exist boolean;
BEGIN
   -- Check if any tenants exist
   SELECT EXISTS(SELECT 1 FROM registry.tenants LIMIT 1) INTO tenants_exist;
   
   -- Only process tenants if they exist
   IF tenants_exist THEN
       FOR s IN SELECT slug FROM registry.tenants LOOP
           -- Check if the schema exists before processing
           IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = s) THEN
               -- Create programs table in tenant schema
               EXECUTE format('CREATE TABLE IF NOT EXISTS "%s".programs (
               id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
               name text UNIQUE NOT NULL,
               slug text UNIQUE NOT NULL,
               description text NULL,
               metadata jsonb NULL,
               notes text NULL,
               created_at timestamp with time zone DEFAULT now(),
               updated_at timestamp NOT NULL DEFAULT current_timestamp
           );', s);

           -- Add program_id to sessions
           EXECUTE format('ALTER TABLE "%s".sessions ADD COLUMN IF NOT EXISTS program_id uuid REFERENCES "%s".programs(id);', s, s);

           -- Add session_id to events
           EXECUTE format('ALTER TABLE "%s".events ADD COLUMN IF NOT EXISTS session_id uuid REFERENCES "%s".sessions(id);', s, s);
           
           -- Drop old project_id from events (if it exists)
           IF EXISTS (SELECT 1 FROM information_schema.columns 
                      WHERE table_schema = s AND table_name = 'events' AND column_name = 'project_id') THEN
               EXECUTE format('ALTER TABLE "%s".events DROP COLUMN project_id;', s);
           END IF;
           
           -- Drop old projects table and recreate as curriculum
           EXECUTE format('DROP TABLE IF EXISTS "%s".projects CASCADE;', s);
           EXECUTE format('CREATE TABLE IF NOT EXISTS "%s".curriculum (
               id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
               name text NOT NULL,
               slug text NOT NULL,
               description text,
               metadata jsonb NULL,
               notes text NULL,
               created_at timestamp with time zone DEFAULT now(),
               updated_at timestamp NOT NULL DEFAULT current_timestamp,
               UNIQUE(slug)
           );', s);
           
           -- Create event_curriculum junction table
           EXECUTE format('CREATE TABLE IF NOT EXISTS "%s".event_curriculum (
               id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
               event_id uuid NOT NULL REFERENCES "%s".events(id) ON DELETE CASCADE,
               curriculum_id uuid NOT NULL REFERENCES "%s".curriculum(id) ON DELETE CASCADE,
               created_at timestamp with time zone DEFAULT now(),
               UNIQUE(event_id, curriculum_id)
           );', s, s, s);
           
           -- Update constraints
           EXECUTE format('ALTER TABLE "%s".events DROP CONSTRAINT IF EXISTS events_project_id_location_id_time_key;', s);

           -- Only add new constraint if it doesn't exist
           IF NOT EXISTS (SELECT 1 FROM information_schema.table_constraints
                          WHERE constraint_name = 'events_session_location_time_unique'
                          AND table_name = 'events' AND table_schema = s) THEN
               EXECUTE format('ALTER TABLE "%s".events ADD CONSTRAINT events_session_location_time_unique
                   UNIQUE (session_id, location_id, time);', s);
           END IF;
               
           -- Update indexes for tenant schema
           EXECUTE format('DROP INDEX IF EXISTS "%s".idx_events_project_id;', s);
           EXECUTE format('CREATE INDEX IF NOT EXISTS idx_events_session_id ON "%s".events(session_id);', s);
           EXECUTE format('CREATE INDEX IF NOT EXISTS idx_sessions_program_id ON "%s".sessions(program_id);', s);
           EXECUTE format('CREATE INDEX IF NOT EXISTS idx_event_curriculum_event_id ON "%s".event_curriculum(event_id);', s);
           EXECUTE format('CREATE INDEX IF NOT EXISTS idx_event_curriculum_curriculum_id ON "%s".event_curriculum(curriculum_id);', s);
           END IF; -- end schema exists check
       END LOOP;
   END IF;
END;
$$ LANGUAGE plpgsql;

COMMIT;