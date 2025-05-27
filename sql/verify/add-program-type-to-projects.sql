-- Verify registry:add-program-type-to-projects on pg

BEGIN;

SET search_path TO registry, public;

-- Verify column exists
SELECT program_type_slug FROM projects WHERE FALSE;

-- Verify constraint exists
SELECT 1 FROM pg_constraint 
WHERE conname = 'fk_projects_program_type';

ROLLBACK;