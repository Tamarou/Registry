-- ABOUTME: Clears the stored offer-publishing and in-studio-class-setup workflows again, in registry only.
-- ABOUTME: Import then rebuilds the shape the reverted code ships; the old steps only ever existed as rows import wrote.

-- Revert registry:offer-publishing-asks-approval from pg

BEGIN;

SET client_min_messages = 'warning';

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
