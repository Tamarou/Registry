-- ABOUTME: Reverts registry-run-right-at-import: drops the import trigger and its function everywhere.
-- ABOUTME: The rights it granted carry workflow-run-entitlements' ids, so that change's revert removes them.

-- Revert registry:registry-run-right-at-import from pg

BEGIN;

SET client_min_messages = 'warning';

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.workflows', s)) IS NULL;
        EXECUTE format('DROP TRIGGER IF EXISTS workflow_registry_run_right ON %I.workflows', s);
        IF s != 'registry' THEN
            EXECUTE format('DROP FUNCTION IF EXISTS %I.workflow_registry_run_right()', s);
        END IF;
    END LOOP;
END $$;

DROP FUNCTION registry.workflow_registry_run_right();
DROP FUNCTION registry.registry_holds_run_right(text);

COMMIT;
