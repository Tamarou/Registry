-- Deploy seed-registry-storefront
-- Seed the registry tenant's storefront with the TinyArtEmpire platform offering.

SET search_path TO registry, public;

-- System user for platform-level records
INSERT INTO users (username, passhash)
VALUES ('system', 'nologin')
ON CONFLICT (username) DO NOTHING;

INSERT INTO user_profiles (user_id, email, name)
SELECT id, 'system@tinyartempire.com', 'System'
FROM users WHERE username = 'system'
ON CONFLICT (user_id) DO NOTHING;

-- Virtual location for the platform
INSERT INTO locations (name, slug, address_info)
VALUES ('Online', 'online', '{"type": "virtual"}'::jsonb)
ON CONFLICT (slug) DO NOTHING;

-- The platform project
INSERT INTO projects (name, slug, notes, metadata)
VALUES (
    'Tiny Art Empire',
    'tiny-art-empire',
    'Start your own art education business. Create programs, manage enrollments, accept payments — all in one platform.',
    '{"registration_workflow": "tenant-signup"}'::jsonb
)
ON CONFLICT (slug) DO NOTHING;

-- Evergreen session (platform is always open for signup)
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

-- Event linking project, location, and teacher
INSERT INTO events (time, duration, location_id, project_id, teacher_id, capacity, event_type, status)
SELECT
    NOW(), 0, l.id, p.id, u.id, 999999, 'registration', 'published'
FROM projects p, locations l, users u
WHERE p.slug = 'tiny-art-empire'
  AND l.slug = 'online'
  AND u.username = 'system'
  AND NOT EXISTS (SELECT 1 FROM events e WHERE e.project_id = p.id);

-- Link session to event
INSERT INTO session_events (session_id, event_id)
SELECT s.id, e.id
FROM sessions s
CROSS JOIN events e
JOIN projects p ON e.project_id = p.id
WHERE s.slug = 'get-started'
  AND p.slug = 'tiny-art-empire'
  AND NOT EXISTS (
    SELECT 1 FROM session_events se WHERE se.session_id = s.id AND se.event_id = e.id
  );
