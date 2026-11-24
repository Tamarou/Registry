-- ABOUTME: Verify every schema has its entitlement units and holds tables.
-- ABOUTME: Checked per schema, because a tenant's units live in its own schema.

-- Verify registry:priceops-entitlement-units on pg

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
        EXECUTE format(
            'SELECT entitlement_id, resource_id, unit FROM %I.entitlement_units WHERE false', s);
        EXECUTE format(
            'SELECT id, resource_id, units, workflow_run_id, expires_at, state FROM %I.holds WHERE false', s);
    END LOOP;
END $$;

ROLLBACK;
