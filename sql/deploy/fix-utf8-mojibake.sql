-- Deploy fix-utf8-mojibake
-- Delete DB templates so the app reimports from the fixed filesystem versions on startup.

BEGIN;

SET search_path TO registry, public;

DELETE FROM templates
WHERE name != 'tenant-storefront/program-listing';

COMMIT;
