-- Revert registry:workflow-step-label from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- The column is nullable and nothing depends on it, so the revert is the drop
-- and nothing else: no constraint to remove, no default left behind on a money
-- column (the shape #297 names), and no enum value that cannot be removed.
ALTER TABLE workflow_steps
  DROP COLUMN IF EXISTS label;

DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN to_regclass(format('%I.workflow_steps', s)) IS NULL;

        EXECUTE format('ALTER TABLE %I.workflow_steps
            DROP COLUMN IF EXISTS label;', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;
