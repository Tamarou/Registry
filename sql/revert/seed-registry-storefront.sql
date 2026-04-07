-- Revert seed-registry-storefront
BEGIN;
SET search_path TO registry, public;

DELETE FROM session_events WHERE session_id = (SELECT id FROM sessions WHERE slug = 'get-started');
DELETE FROM events WHERE project_id = (SELECT id FROM projects WHERE slug = 'tiny-art-empire');
DELETE FROM sessions WHERE slug = 'get-started';
DELETE FROM projects WHERE slug = 'tiny-art-empire';

COMMIT;
