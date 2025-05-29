-- Deploy registry:summer-camp-module to pg
-- requires: events-and-sessions

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Update locations table with summer camp specific fields
ALTER TABLE locations ADD COLUMN IF NOT EXISTS address_street text;
ALTER TABLE locations ADD COLUMN IF NOT EXISTS address_city text;
ALTER TABLE locations ADD COLUMN IF NOT EXISTS address_state text;
ALTER TABLE locations ADD COLUMN IF NOT EXISTS address_zip text;
ALTER TABLE locations ADD COLUMN IF NOT EXISTS capacity integer;
ALTER TABLE locations ADD COLUMN IF NOT EXISTS contact_info jsonb;
ALTER TABLE locations ADD COLUMN IF NOT EXISTS facilities jsonb;
ALTER TABLE locations ADD COLUMN IF NOT EXISTS latitude decimal(10, 8);
ALTER TABLE locations ADD COLUMN IF NOT EXISTS longitude decimal(11, 8);

-- Update sessions table to reflect revised architecture
ALTER TABLE sessions
ADD COLUMN IF NOT EXISTS session_type text DEFAULT 'regular';
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS start_date date;
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS end_date date;
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS status text DEFAULT 'draft'
CHECK (status IN ('draft', 'published', 'closed'));

-- Update events table with new fields
ALTER TABLE events ADD COLUMN IF NOT EXISTS min_age integer;
ALTER TABLE events ADD COLUMN IF NOT EXISTS max_age integer;
ALTER TABLE events ADD COLUMN IF NOT EXISTS capacity integer;

-- Create session_teachers junction table
CREATE TABLE IF NOT EXISTS session_teachers (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    session_id uuid NOT NULL REFERENCES sessions,
    teacher_id uuid NOT NULL REFERENCES users,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp NOT NULL DEFAULT current_timestamp,

    UNIQUE (session_id, teacher_id)
);

-- Create pricing table linked to events
CREATE TABLE IF NOT EXISTS pricing (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    session_id uuid NOT NULL REFERENCES sessions,
    amount decimal(10, 2) NOT NULL,
    currency text DEFAULT 'USD',
    early_bird_amount decimal(10, 2),
    early_bird_cutoff_date date,
    sibling_discount decimal(5, 2),
    metadata jsonb NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp NOT NULL DEFAULT current_timestamp,

    -- Only one price per event
    UNIQUE (session_id)
);

-- Create enrollments table
CREATE TABLE IF NOT EXISTS enrollments (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    session_id uuid NOT NULL REFERENCES sessions,
    student_id uuid NOT NULL REFERENCES users,
    status text DEFAULT 'active' CHECK (
        status IN ('pending', 'active', 'cancelled', 'waitlisted')
    ),
    metadata jsonb NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp NOT NULL DEFAULT current_timestamp,

    -- A student can only be enrolled once in an event
    UNIQUE (session_id, student_id)
);

-- Propagate schema changes to tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
   FOR s IN SELECT slug FROM registry.tenants LOOP
       -- Update locations table
       EXECUTE format('ALTER TABLE %I.locations ADD COLUMN IF NOT EXISTS address_street text;', s);
       EXECUTE format('ALTER TABLE %I.locations ADD COLUMN IF NOT EXISTS address_city text;', s);
       EXECUTE format('ALTER TABLE %I.locations ADD COLUMN IF NOT EXISTS address_state text;', s);
       EXECUTE format('ALTER TABLE %I.locations ADD COLUMN IF NOT EXISTS address_zip text;', s);
       EXECUTE format('ALTER TABLE %I.locations ADD COLUMN IF NOT EXISTS capacity integer;', s);
       EXECUTE format('ALTER TABLE %I.locations ADD COLUMN IF NOT EXISTS contact_info jsonb;', s);
       EXECUTE format('ALTER TABLE %I.locations ADD COLUMN IF NOT EXISTS facilities jsonb;', s);
       EXECUTE format('ALTER TABLE %I.locations ADD COLUMN IF NOT EXISTS latitude decimal(10, 8);', s);
       EXECUTE format('ALTER TABLE %I.locations ADD COLUMN IF NOT EXISTS longitude decimal(11, 8);', s);

       -- Update sessions table
       EXECUTE format('ALTER TABLE %I.sessions ADD COLUMN IF NOT EXISTS session_type text DEFAULT ''regular'';', s);
       EXECUTE format('ALTER TABLE %I.sessions ADD COLUMN IF NOT EXISTS capacity integer;', s);

       -- Update events table - add columns
       EXECUTE format('ALTER TABLE %I.events ADD COLUMN IF NOT EXISTS event_type text DEFAULT ''class'';', s);
       EXECUTE format('ALTER TABLE %I.events ADD COLUMN IF NOT EXISTS status text DEFAULT ''draft'' CHECK (status IN (''draft'', ''published'', ''closed''));', s);

       -- Create session_teachers table
       EXECUTE format('CREATE TABLE IF NOT EXISTS %I.session_teachers (
           id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
           session_id uuid NOT NULL REFERENCES %I.sessions,
           teacher_id uuid NOT NULL REFERENCES %I.users,
           created_at timestamp with time zone DEFAULT now(),
           updated_at timestamp NOT NULL DEFAULT current_timestamp,
           UNIQUE (session_id, teacher_id)
       );', s, s, s);

       -- Create pricing table
       EXECUTE format('CREATE TABLE IF NOT EXISTS %I.pricing (
           id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
           session_id uuid NOT NULL REFERENCES %I.sessions,
           amount decimal(10,2) NOT NULL,
           currency text DEFAULT ''USD'',
           early_bird_amount decimal(10,2),
           early_bird_cutoff_date date,
           sibling_discount decimal(5,2),
           metadata jsonb NULL,
           created_at timestamp with time zone DEFAULT now(),
           updated_at timestamp NOT NULL DEFAULT current_timestamp,
           UNIQUE (session_id)
       );', s, s);

       -- Create enrollments table
       EXECUTE format('CREATE TABLE IF NOT EXISTS %I.enrollments (
           id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
           session_id uuid NOT NULL REFERENCES %I.sessions,
           student_id uuid NOT NULL REFERENCES %I.users,
           status text DEFAULT ''active'' CHECK (status IN (''pending'', ''active'', ''cancelled'', ''waitlisted'')),
           metadata jsonb NULL,
           created_at timestamp with time zone DEFAULT now(),
           updated_at timestamp NOT NULL DEFAULT current_timestamp,
           UNIQUE (session_id, student_id)
       );', s, s, s);
   END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;
