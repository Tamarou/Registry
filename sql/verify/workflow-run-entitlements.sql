-- ABOUTME: Verify the run-right guard exists in registry. Not registry's rights per workflow: import adds
-- ABOUTME: workflows after deploy, so that would fail a later verify for data, not for this change.

-- Verify registry:workflow-run-entitlements on pg

BEGIN;

DO $$
BEGIN
    IF to_regprocedure('registry.entitlement_one_run_right()') IS NULL
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'registry.entitlements'::regclass
                                                 AND tgname = 'entitlement_one_run_right')
    THEN
        RAISE EXCEPTION 'the run-right guard is missing';
    END IF;
END $$;

ROLLBACK;
