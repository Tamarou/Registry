-- ABOUTME: Clears the stored offer-publishing workflow again so the importer rebuilds the shape the reverted code ships.
-- ABOUTME: The old steps cannot be restored here -- they only ever existed as rows the importer wrote from YAML.

-- Revert registry:offer-publishing-adds-expiry-policy from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

DO $$
DECLARE
    wf uuid;
BEGIN
    SELECT id INTO wf FROM workflows WHERE slug = 'offer-publishing';
    IF wf IS NULL THEN
        RETURN;
    END IF;

    DELETE FROM workflow_runs  WHERE workflow_id = wf;
    DELETE FROM workflow_steps WHERE workflow_id = wf;
    DELETE FROM workflows      WHERE id = wf;
END $$;

COMMIT;
