-- ABOUTME: Clears the stored tenant-signup workflow so the importer rebuilds it without the plan and payment steps.
-- ABOUTME: Workflow::from_yaml returns an existing workflow untouched, so the YAML alone changes nothing already deployed.

-- Deploy registry:tenant-signup-drop-plan-page to pg
-- requires: user-deactivation

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Signup no longer asks which plan: Solo is the only tier on sale, it costs
-- nothing up front, and the two greyed-out tiers were refused server-side
-- anyway. With no plan to buy there is nothing to charge, so the payment step
-- goes with it and the review page becomes the commit point.
--
-- This migration exists because importing the YAML is not enough. Workflow's
-- from_yaml short-circuits on an existing slug and returns the stored workflow
-- unchanged -- it reports the file's step count while leaving the old steps in
-- place -- so a deployed workflow can only be reshaped by removing it first.
-- docker-entrypoint.sh runs `registry workflow import` immediately after
-- sqitch deploy, which is what puts the new shape back.
DO $$
DECLARE
    wf uuid;
BEGIN
    SELECT id INTO wf FROM workflows WHERE slug = 'tenant-signup';
    IF wf IS NULL THEN
        RETURN;
    END IF;

    -- In-flight signups do not survive. Nobody is onboarded yet, and a run
    -- pointing at a step that no longer exists is worse than one that is gone.
    DELETE FROM workflow_runs WHERE workflow_id = wf;

    -- depends_on is ON DELETE CASCADE, so removing the head takes the chain;
    -- deleting by workflow_id is explicit about what is going and does not
    -- depend on which end the cascade starts from.
    DELETE FROM workflow_steps WHERE workflow_id = wf;

    DELETE FROM workflows WHERE id = wf;
END $$;

COMMIT;
