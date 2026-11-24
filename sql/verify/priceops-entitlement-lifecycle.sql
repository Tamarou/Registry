-- ABOUTME: Verify every schema's entitlements carry their lifecycle state, ending and payment link.
-- ABOUTME: Checked per schema, because a tenant's entitlements live in its own schema.

-- Verify registry:priceops-entitlement-lifecycle on pg

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
        EXECUTE format('SELECT state, ended_at, ended_reason, payment_id, payment_share_cents FROM %I.entitlements WHERE false', s);
    END LOOP;
END $$;

ROLLBACK;
