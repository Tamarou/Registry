-- Verify update-registry-landing-copy on pg

BEGIN;

SET search_path TO registry, public;

SELECT 1 FROM templates
WHERE name = 'tenant-storefront/program-listing'
  AND content LIKE '%no monthly fees%';

ROLLBACK;
