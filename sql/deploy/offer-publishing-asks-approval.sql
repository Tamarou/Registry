-- ABOUTME: Clears the stored offer-publishing and in-studio-class-setup workflows, in registry only.
-- ABOUTME: Their policy steps now ask for approval, change targets, price difference and make-ups; import rebuilds them.

-- Deploy registry:offer-publishing-asks-approval to pg
-- requires: parallel-session-days

BEGIN;

SET client_min_messages = 'warning';

-- Workflow::from_yaml returns an existing workflow untouched, so the stored
-- copies go and `registry workflow import` writes the new shape. In-flight
-- runs go with them: a run whose policies lack approval could not publish.
-- Registry only: a migration never overwrites a tenant's copy (see
-- t/dao/offer-publishing-tenant-copies.t). A new run on a tenant's older copy
-- still publishes, since the steps save an unasked approval, price difference
-- or target as OfferVersion reads its absence. An unfinished tenant run whose
-- saved refund or change answer lacks approval is refused at publish until
-- the admin answers that step again.
DO $$
DECLARE
    wf uuid;
BEGIN
    FOR wf IN SELECT id FROM registry.workflows WHERE slug IN ('offer-publishing', 'in-studio-class-setup') LOOP
        DELETE FROM registry.workflow_runs  WHERE workflow_id = wf;
        DELETE FROM registry.workflow_steps WHERE workflow_id = wf;
        DELETE FROM registry.workflows      WHERE id = wf;
    END LOOP;
END $$;

COMMIT;
