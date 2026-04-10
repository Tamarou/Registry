-- Deploy seed-registry-storefront
-- Seed the registry tenant's storefront with the TinyArtEmpire platform offering.
-- The project's registration_workflow metadata tells the storefront template
-- which workflow to callcc into (tenant-signup instead of summer-camp-registration).

BEGIN;

SET search_path TO registry, public;

-- Create a virtual location for the platform (online)
INSERT INTO locations (name, slug, address_info, metadata)
VALUES (
    'Online',
    'online',
    '{"type": "virtual"}'::jsonb,
    '{}'::jsonb
)
ON CONFLICT (slug) DO NOTHING;

-- Create a system user to satisfy the teacher_id foreign key
INSERT INTO users (username, user_type)
VALUES ('system', 'staff')
ON CONFLICT (username) DO NOTHING;

-- Create the platform project
INSERT INTO projects (name, slug, notes, program_type_slug, metadata)
VALUES (
    'Tiny Art Empire',
    'tiny-art-empire',
    'Start your own art education business. Create programs, manage enrollments, accept payments — all in one platform.',
    NULL,
    '{"registration_workflow": "tenant-signup", "description": "The complete platform for running art education programs."}'::jsonb
)
ON CONFLICT (slug) DO NOTHING;

-- Create an evergreen session (the platform is always "open")
INSERT INTO sessions (name, slug, start_date, end_date, status, capacity)
VALUES (
    'Get Started Today',
    'get-started',
    CURRENT_DATE,
    CURRENT_DATE + INTERVAL '10 years',
    'published',
    999999
)
ON CONFLICT (slug) DO NOTHING;

-- Create a placeholder event linking the project to the online location
INSERT INTO events (time, duration, project_id, location_id, teacher_id, capacity, event_type, status)
SELECT
    NOW(),
    0,
    p.id,
    l.id,
    u.id,
    999999,
    'registration',
    'published'
FROM projects p, locations l, users u
WHERE p.slug = 'tiny-art-empire'
  AND l.slug = 'online'
  AND u.username = 'system'
  AND NOT EXISTS (
    SELECT 1 FROM events e WHERE e.project_id = p.id
  );

-- Link session to event via session_events
INSERT INTO session_events (session_id, event_id)
SELECT s.id, e.id
FROM sessions s, events e
JOIN projects p ON e.project_id = p.id
WHERE s.slug = 'get-started'
  AND p.slug = 'tiny-art-empire'
  AND NOT EXISTS (
    SELECT 1 FROM session_events se WHERE se.session_id = s.id AND se.event_id = e.id
  );

COMMIT;
