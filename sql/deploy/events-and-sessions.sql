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
    created_at timestamp with time zone DEFAULT now()
);

CREATE TABLE IF NOT EXISTS projects (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    name text UNIQUE NOT NULL,
    slug text UNIQUE NOT NULL,
    metadata jsonb NULL,
    notes text NULL,
    created_at timestamp with time zone DEFAULT now()
);

CREATE TABLE IF NOT EXISTS sessions (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    name text UNIQUE NOT NULL,
    slug text UNIQUE NOT NULL,
    metadata jsonb NULL,
    notes text NULL,
    created_at timestamp with time zone DEFAULT now()
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
    -- only one event in one place at a time
    UNIQUE (project_id, location_id, time)
);

CREATE TABLE IF NOT EXISTS session_events (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    session_id uuid NOT NULL REFERENCES sessions,
    event_id uuid NOT NULL REFERENCES events,
    created_at timestamp with time zone DEFAULT now()
);

DO
$$
DECLARE
    s name;
BEGIN
   FOR s IN SELECT slug FROM registry.customers LOOP
       EXECUTE format('CREATE TABLE IF NOT EXISTS %I.locations AS TABLE registry.locations;', s);
       EXECUTE format('CREATE TABLE IF NOT EXISTS %I.projects AS TABLE registry.projects;', s);
       EXECUTE format('CREATE TABLE IF NOT EXISTS %I.sessions AS TABLE registry.sessions;', s);
       EXECUTE format('CREATE TABLE IF NOT EXISTS %I.events AS TABLE registry.events;', s);
       EXECUTE format('CREATE TABLE IF NOT EXISTS %I.session_events AS TABLE registry.session_events;', s);
   END LOOP;
END;
$$ LANGUAGE plpgsql;


-- CREATE THE BASIC EVENT CREATION WORKFLOW

INSERT INTO workflows (name, slug, description)
VALUES ('Event Creation', 'event-creation', 'A workflow to create new events');

INSERT INTO workflow_steps (slug, workflow_id, description)
VALUES (
    'landing',
    (SELECT id FROM workflows WHERE slug = 'event-creation'),
    'New Event Landing page'
);

INSERT INTO workflow_steps (slug, workflow_id, description, depends_on)
VALUES (
    'info',
    (SELECT id FROM workflows WHERE slug = 'event-creation'),
    'Event info',
    (
        SELECT id
        FROM workflow_steps
        WHERE
            slug = 'landing'
            AND workflow_id
            = (SELECT id FROM workflows WHERE slug = 'event-creation')
    )
);

INSERT INTO workflow_steps (slug, workflow_id, description, depends_on, class)
VALUES (
    'complete',
    (SELECT id FROM workflows WHERE slug = 'event-creation'),
    'Event creation complete',
    (SELECT id FROM workflow_steps WHERE slug = 'info'),
    'Registry::DAO::CreateEvent'
);

-- CREATE THE BASIC SESSION CREATION WORKFLOW

INSERT INTO workflows (name, slug, description)
VALUES (
    'Session Creation', 'session-creation', 'A workflow to create new sessions'
);

INSERT INTO workflow_steps (slug, workflow_id, description)
VALUES (
    'landing',
    (SELECT id FROM workflows WHERE slug = 'session-creation'),
    'New Session Landing page'
);

INSERT INTO workflow_steps (slug, workflow_id, description, depends_on)
VALUES (
    'info',
    (SELECT id FROM workflows WHERE slug = 'session-creation'),
    'Session info',
    (
        SELECT id
        FROM workflow_steps
        WHERE
            slug = 'landing'
            AND workflow_id
            = (SELECT id FROM workflows WHERE slug = 'session-creation')
    )
);

INSERT INTO workflow_steps (slug, workflow_id, description, depends_on, class)
VALUES (
    'complete',
    (SELECT id FROM workflows WHERE slug = 'session-creation'),
    'Session creation complete',
    (
        SELECT id
        FROM workflow_steps
        WHERE
            slug = 'info'
            AND workflow_id
            = (SELECT id FROM workflows WHERE slug = 'session-creation')
    ),
    'Registry::DAO::CreateSession'
);

COMMIT;
