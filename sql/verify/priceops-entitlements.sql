-- ABOUTME: Verify every schema has its entitlements table with the stamp columns.
-- ABOUTME: Checked per schema, because a tenant's entitlements live in its own schema.

-- Verify registry:priceops-entitlements on pg

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
        CONTINUE WHEN to_regclass(format('%I.offer_versions', s)) IS NULL;
        EXECUTE format(
            'SELECT id, holder_user_id, holder_family_member_id, holder_tenant_id, payer_user_id, offer_version_id, payment_plan_id FROM %I.entitlements WHERE false', s);
    END LOOP;
END $$;

ROLLBACK;
