-- Deploy registry:events-and-sessions to pg
-- requires: schema-based-multitennancy

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

CREATE TABLE IF NOT EXISTS locations (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    name text UNIQUE NOT NULL,
    slug text UNIQUE NOT NULL,
    metadata jsonb NULL,
    notes text NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp NOT NULL DEFAULT current_timestamp
);

CREATE TABLE IF NOT EXISTS projects (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    name text UNIQUE NOT NULL,
    slug text UNIQUE NOT NULL,
    metadata jsonb NULL,
    notes text NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp NOT NULL DEFAULT current_timestamp
);

CREATE TABLE IF NOT EXISTS sessions (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    name text UNIQUE NOT NULL,
    slug text UNIQUE NOT NULL,
    metadata jsonb NULL,
    notes text NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp NOT NULL DEFAULT current_timestamp

);

CREATE TABLE IF NOT EXISTS events (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    time timestamp with time zone NOT NULL,
    duration int NOT NULL DEFAULT 0,
    location_id uuid NOT NULL REFERENCES locations,
    project_id uuid NOT NULL REFERENCES projects,
    teacher_id uuid NOT NULL REFERENCES users,
    metadata jsonb NULL,
    notes text NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp NOT NULL DEFAULT current_timestamp,

    -- only one event in one place at a time
    UNIQUE (project_id, location_id, time)
);

CREATE TABLE IF NOT EXISTS session_events (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    session_id uuid NOT NULL REFERENCES sessions,
    event_id uuid NOT NULL REFERENCES events,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp NOT NULL DEFAULT current_timestamp

);

DO
$$
DECLARE
    s name;
BEGIN
   FOR s IN SELECT slug FROM registry.tenants LOOP
       EXECUTE format('CREATE TABLE IF NOT EXISTS %I.locations AS TABLE registry.locations;', s);
       EXECUTE format('CREATE TABLE IF NOT EXISTS %I.projects AS TABLE registry.projects;', s);
       EXECUTE format('CREATE TABLE IF NOT EXISTS %I.sessions AS TABLE registry.sessions;', s);
       EXECUTE format('CREATE TABLE IF NOT EXISTS %I.events AS TABLE registry.events;', s);
       EXECUTE format('CREATE TABLE IF NOT EXISTS %I.session_events AS TABLE registry.session_events;', s);
   END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;
