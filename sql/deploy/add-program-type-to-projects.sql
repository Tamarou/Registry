-- Deploy registry:add-program-type-to-projects to pg
-- requires: program-types
-- NOTE: This migration is a no-op as the restructure-data-model migration
-- supersedes this functionality by replacing projects table with programs table

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- No-op: This migration is superseded by restructure-data-model
-- The projects table is replaced by programs table which includes program type support

COMMIT;