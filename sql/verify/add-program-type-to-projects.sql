-- Verify registry:add-program-type-to-projects on pg
-- NOTE: This migration is a no-op as the restructure-data-model migration
-- supersedes this functionality by replacing projects table with programs table

BEGIN;

SET search_path TO registry, public;

-- No-op verification: This migration is superseded by restructure-data-model
-- The functionality is now in the programs table instead of projects table

ROLLBACK;