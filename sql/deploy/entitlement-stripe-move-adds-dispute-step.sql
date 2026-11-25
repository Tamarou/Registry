-- ABOUTME: Clears the stored entitlement-stripe-move workflow so the importer rebuilds it with the dispute step.
-- ABOUTME: Workflow::from_yaml returns an existing workflow untouched, so the YAML alone changes nothing already deployed.

-- Deploy registry:entitlement-stripe-move-adds-dispute-step to pg
-- requires: retire-launch-rate-marker

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- entitlement-stripe-move gains an apply-dispute step after apply-refund, so
-- a lost dispute ends the entitlements its payment bought. from_yaml
-- short-circuits on an existing slug, so the stored workflow goes and
-- `registry workflow import`, which docker-entrypoint.sh runs right after
-- sqitch deploy, writes the new shape. A run that goes with it leaves its
-- stored event unapplied (processed_at NULL), not lost.
DO $$
DECLARE
    wf uuid;
BEGIN
    SELECT id INTO wf FROM workflows WHERE slug = 'entitlement-stripe-move';
    IF wf IS NULL THEN
        RETURN;
    END IF;

    DELETE FROM workflow_runs  WHERE workflow_id = wf;
    DELETE FROM workflow_steps WHERE workflow_id = wf;
    DELETE FROM workflows      WHERE id = wf;
END $$;

COMMIT;
