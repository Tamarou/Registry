-- Revert registry-landing-page-template from pg
-- Restores the generic program listing template. After reverting, run
-- `carton exec ./registry template import registry` to reload from filesystem.

BEGIN;

SET search_path TO registry, public;

DELETE FROM templates WHERE name = 'tenant-storefront/program-listing';

COMMIT;
