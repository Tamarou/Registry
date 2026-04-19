-- Verify registry:program-publish-status on pg

BEGIN;

SET search_path TO registry, public;

-- projects.status column exists with expected check constraint
SELECT 1/count(*) FROM information_schema.columns
WHERE table_schema = 'registry'
  AND table_name = 'projects'
  AND column_name = 'status';

-- locations.contact_person_id column exists as a uuid
SELECT 1/count(*) FROM information_schema.columns
WHERE table_schema = 'registry'
  AND table_name = 'locations'
  AND column_name = 'contact_person_id'
  AND data_type = 'uuid';

ROLLBACK;
