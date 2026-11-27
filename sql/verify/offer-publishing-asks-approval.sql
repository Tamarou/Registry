-- ABOUTME: Verify registry's stored offer-publishing, if any, has a refund step that asks for approval.
-- ABOUTME: Passes when the workflow is absent (before import) and once import has rebuilt it from the current YAML.

-- Verify registry:offer-publishing-asks-approval on pg

BEGIN;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM registry.workflows w JOIN registry.workflow_steps s ON s.workflow_id = w.id
         WHERE w.slug = 'offer-publishing' AND s.slug = 'refund-policy' AND s.description NOT LIKE '%approves%'
    ) THEN
        RAISE EXCEPTION 'offer-publishing is stored with a refund step that does not ask for approval';
    END IF;
END $$;

ROLLBACK;
