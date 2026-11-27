-- ABOUTME: Verify every schema's entitlement uses carry the day, its mark and the make-up credit link.
-- ABOUTME: Checked per schema, because a tenant's uses live in its own schema.

-- Verify registry:entitlement-uses-per-day on pg

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
        CONTINUE WHEN to_regclass(format('%I.entitlement_uses', s)) IS NULL;
        EXECUTE format(
            'SELECT event_id, mark, credit_entitlement_id FROM %I.entitlement_uses WHERE false', s);
    END LOOP;
END $$;

ROLLBACK;
