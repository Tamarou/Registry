-- Revert registry:workflows from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry,public;

DROP TABLE IF EXISTS templates CASCADE;
DROP TABLE IF EXISTS workflow_step_runs CASCADE;
DROP TABLE IF EXISTS workflow_steps CASCADE;
DROP TABLE IF EXISTS workflows CASCADE;

COMMIT;
