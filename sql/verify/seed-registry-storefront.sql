-- Verify registry:seed-registry-storefront on pg

BEGIN;

SET search_path TO registry, public;

SELECT 1 FROM projects WHERE slug = 'tiny-art-empire';
SELECT 1 FROM sessions WHERE slug = 'get-started';

ROLLBACK;
