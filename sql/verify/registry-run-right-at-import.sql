-- ABOUTME: Verify registry grants itself a workflow's run right on import: the function and its trigger exist.
-- ABOUTME: Not the rights themselves, which follow the data import adds after deploy.

-- Verify registry:registry-run-right-at-import on pg

BEGIN;

DO $$
BEGIN
    IF to_regprocedure('registry.registry_holds_run_right(text)') IS NULL
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'registry.workflows'::regclass
                                                 AND tgname = 'workflow_registry_run_right')
    THEN
        RAISE EXCEPTION 'registry is not granted run rights on import';
    END IF;
END $$;

ROLLBACK;
