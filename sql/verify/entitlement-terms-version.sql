-- ABOUTME: Verify every entitlements table, in registry and each tenant schema, has the agreed terms version.
-- ABOUTME: Checked per schema, because a tenant's entitlements live in its own schema.

-- Verify registry:entitlement-terms-version on pg

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
        EXECUTE format('SELECT terms_version FROM %I.entitlements WHERE false', s);
    END LOOP;
END $$;

ROLLBACK;
