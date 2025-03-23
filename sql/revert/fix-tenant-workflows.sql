-- Revert registry:fix-tenant-workflows from pg

BEGIN;

-- Nothing to revert as this is just a data fix 
-- We could technically revert the first_step values, but that would break functionality

COMMIT;
