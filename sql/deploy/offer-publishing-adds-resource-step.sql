-- ABOUTME: Clears the stored offer-publishing workflow so the importer rebuilds it with the resource step first.
-- ABOUTME: Workflow::from_yaml returns an existing workflow untouched, so the YAML alone changes nothing already deployed.

-- Deploy registry:offer-publishing-adds-resource-step to pg
-- requires: offer-publishing-adds-use-policy

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- offer-publishing now starts at a resource step (use, create, or cover a
-- class). As with tenant-signup-drop-plan-page, removing the stored workflow
-- is the only way to reshape it: `registry workflow import`, which
-- docker-entrypoint.sh runs after sqitch deploy, writes the new shape.
DO $$
DECLARE
    wf uuid;
BEGIN
    SELECT id INTO wf FROM workflows WHERE slug = 'offer-publishing';
    IF wf IS NULL THEN
        RETURN;
    END IF;

    -- In-flight runs do not survive: a run whose first step was offer-basics
    -- would skip the resource step. Nobody is publishing offers yet.
    DELETE FROM workflow_runs  WHERE workflow_id = wf;
    DELETE FROM workflow_steps WHERE workflow_id = wf;
    DELETE FROM workflows      WHERE id = wf;
END $$;

COMMIT;
