-- Verify registry:outcomes on pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Verify outcome_definitions table exists with all columns
SELECT
    id,
    name,
    description,
    schema,
    created_at,
    updated_at
FROM outcome_definitions WHERE FALSE;

-- Verify workflow_steps has outcome_definition_id column
SELECT outcome_definition_id FROM workflow_steps WHERE FALSE;

ROLLBACK;
