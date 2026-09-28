-- ABOUTME: Verify no stored tenant-signup workflow still carries a plan-choice or payment step.
-- ABOUTME: Passes when the workflow is absent (pre-import) and when it has been re-imported from the current YAML.

-- Verify registry:tenant-signup-drop-plan-page on pg

BEGIN;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM registry.workflow_steps s
          JOIN registry.workflows w ON w.id = s.workflow_id
         WHERE w.slug = 'tenant-signup'
           AND s.slug IN ('pricing', 'payment')
    ) THEN
        RAISE EXCEPTION
            'tenant-signup still has a pricing or payment step stored';
    END IF;
END $$;

ROLLBACK;
