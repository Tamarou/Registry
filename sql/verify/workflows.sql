-- Verify registry:workflows on pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

SELECT
    id,
    slug,
    name,
    description,
    first_step
FROM workflows WHERE FALSE;

SELECT
    id,
    description,
    slug,
    workflow_id,
    template_id,
    metadata,
    depends_on
FROM workflow_steps WHERE FALSE;

SELECT
    id,
    workflow_id,
    latest_step_id,
    user_id,
    data,
    created_at
FROM workflow_runs WHERE FALSE;

ROLLBACK;
