-- ABOUTME: Verify every schema with entitlements has the approval queue
-- ABOUTME: and its one-request-per-run constraint.

-- Verify registry:entitlement-requests on pg

BEGIN;

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.entitlements', s)) IS NULL;
        EXECUTE format('SELECT id, entitlement_id, kind, workflow_run_id, outcome, state, requested_by, '
                       'decided_by, decided_at, note, created_at FROM %I.entitlement_requests WHERE false', s);
        IF to_regclass(format('%I.entitlement_requests_workflow_run_id_key', s)) IS NULL THEN
            RAISE EXCEPTION 'schema % lacks the one-request-per-run constraint', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
