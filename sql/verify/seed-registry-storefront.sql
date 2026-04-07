-- Verify seed-registry-storefront
SET search_path TO registry, public;
SELECT id FROM projects WHERE slug = 'tiny-art-empire';
SELECT id FROM sessions WHERE slug = 'get-started';
