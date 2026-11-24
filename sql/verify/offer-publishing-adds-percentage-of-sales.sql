-- ABOUTME: Verify no stored offer-publishing workflow lacks the percentage-of-sales-payment step.
-- ABOUTME: Passes when the workflow is absent (pre-import) and when it has been re-imported from the current YAML.

-- Verify registry:offer-publishing-adds-percentage-of-sales on pg

BEGIN;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM registry.workflows w
         WHERE w.slug = 'offer-publishing'
           AND NOT EXISTS (
               SELECT 1 FROM registry.workflow_steps s
                WHERE s.workflow_id = w.id AND s.slug = 'percentage-of-sales-payment'
           )
    ) THEN
        RAISE EXCEPTION
            'offer-publishing is stored without its percentage-of-sales-payment step';
    END IF;
END $$;

ROLLBACK;
