-- ABOUTME: Clears the stored tenant-signup workflow again so the importer rebuilds the shape the reverted code ships.
-- ABOUTME: The old steps cannot be restored here -- they only ever existed as rows the importer wrote from YAML.

-- Revert registry:tenant-signup-drop-plan-page from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Deploy removed the workflow so `registry workflow import` could write the new
-- shape. Revert does the same thing for the same reason: whatever YAML the
-- reverted checkout ships is the shape that should be stored, and from_yaml
-- will not overwrite a workflow that is already there.
DO $$
DECLARE
    wf uuid;
BEGIN
    SELECT id INTO wf FROM workflows WHERE slug = 'tenant-signup';
    IF wf IS NULL THEN
        RETURN;
    END IF;

    DELETE FROM workflow_runs  WHERE workflow_id = wf;
    DELETE FROM workflow_steps WHERE workflow_id = wf;
    DELETE FROM workflows      WHERE id = wf;
END $$;

COMMIT;
