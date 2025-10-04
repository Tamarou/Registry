-- Revert registry:add-program-type-to-projects from pg
-- NOTE: This migration is a no-op as the restructure-data-model migration
-- supersedes this functionality by replacing projects table with programs table

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- No-op revert: This migration is superseded by restructure-data-model
-- Nothing to revert since the deploy was a no-op

COMMIT;