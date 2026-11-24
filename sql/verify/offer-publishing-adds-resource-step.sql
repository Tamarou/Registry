-- ABOUTME: Verify a stored offer-publishing workflow, if any, starts at the resource step.
-- ABOUTME: Passes when the workflow is absent (pre-import) and when it has been re-imported from the current YAML.

-- Verify registry:offer-publishing-adds-resource-step on pg

BEGIN;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM registry.workflows w
         WHERE w.slug = 'offer-publishing'
           AND w.first_step IS DISTINCT FROM 'resource'
    ) THEN
        RAISE EXCEPTION 'offer-publishing is stored without the resource step first';
    END IF;
END $$;

ROLLBACK;
