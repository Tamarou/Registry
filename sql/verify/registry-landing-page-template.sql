-- Verify registry-landing-page-template on pg

BEGIN;

SET search_path TO registry, public;

SELECT 1 FROM templates
WHERE name = 'tenant-storefront/program-listing'
  AND content LIKE '%Your art deserves a real business%'
  AND length(content) > 1000;

ROLLBACK;
