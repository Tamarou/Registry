-- ABOUTME: Verify no stored entitlement-stripe-move workflow lacks the apply-dispute step.
-- ABOUTME: Passes when the workflow is absent (pre-import) and when it has been re-imported from the current YAML.

-- Verify registry:entitlement-stripe-move-adds-dispute-step on pg

BEGIN;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM registry.workflows w
         WHERE w.slug = 'entitlement-stripe-move'
           AND NOT EXISTS (
               SELECT 1 FROM registry.workflow_steps s
                WHERE s.workflow_id = w.id AND s.slug = 'apply-dispute'
           )
    ) THEN
        RAISE EXCEPTION
            'entitlement-stripe-move is stored without its apply-dispute step';
    END IF;
END $$;

ROLLBACK;
