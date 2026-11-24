-- ABOUTME: Clears the stored offer-publishing workflow so the importer rebuilds it with the percentage-of-sales step.
-- ABOUTME: Workflow::from_yaml returns an existing workflow untouched, so the YAML alone changes nothing already deployed.

-- Deploy registry:offer-publishing-adds-percentage-of-sales to pg
-- requires: platform-entitlement-replaces-plan-link

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- A stored workflow can only be reshaped by removing it first (precedent:
-- tenant-signup-drop-plan-page); docker-entrypoint.sh runs `registry workflow
-- import` right after sqitch deploy, which puts the new shape back. In-flight
-- runs go with it: they point at steps that are about to be gone.
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
