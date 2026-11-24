-- ABOUTME: Clears the stored offer-publishing workflow so the importer rebuilds it with the expiry-policy step.
-- ABOUTME: Workflow::from_yaml returns an existing workflow untouched, so the YAML alone changes nothing already deployed.

-- Deploy registry:offer-publishing-adds-expiry-policy to pg
-- requires: offer-publishing-adds-change-policy

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- offer-publishing gains an expiry-policy step before publish, and publish now
-- refuses a run that never chose one. from_yaml short-circuits on an existing
-- slug, so the stored workflow goes and `registry workflow import`, which
-- docker-entrypoint.sh runs right after sqitch deploy, writes the new shape.
-- In-flight runs go with it: a run that skipped the new step could not publish.
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
