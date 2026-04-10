-- Revert registry:seed-registry-storefront from pg

BEGIN;

SET search_path TO registry, public;

DELETE FROM session_events
WHERE session_id IN (SELECT id FROM sessions WHERE slug = 'get-started')
  AND event_id IN (SELECT e.id FROM events e JOIN projects p ON e.project_id = p.id WHERE p.slug = 'tiny-art-empire');

DELETE FROM events WHERE project_id IN (SELECT id FROM projects WHERE slug = 'tiny-art-empire');
DELETE FROM sessions WHERE slug = 'get-started';
DELETE FROM projects WHERE slug = 'tiny-art-empire';
DELETE FROM locations WHERE slug = 'online';
DELETE FROM users WHERE username = 'system';

COMMIT;
