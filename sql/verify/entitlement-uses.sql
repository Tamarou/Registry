-- ABOUTME: Verify every schema has its entitlement uses table.
-- ABOUTME: Checked per schema, because a tenant's uses live in its own schema.

-- Verify registry:entitlement-uses on pg

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
            'SELECT entitlement_id, occurrence_id, recorded_by, recorded_at FROM %I.entitlement_uses WHERE false', s);
    END LOOP;
END $$;

ROLLBACK;
