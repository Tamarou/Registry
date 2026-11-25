-- ABOUTME: Verify every schema records a Stripe refund once per entitlement.
-- ABOUTME: Checked per schema, because a tenant's refund records live in its own schema.

-- Verify registry:entitlement-refunds-per-entitlement on pg

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
        CONTINUE WHEN to_regclass(format('%I.entitlement_refunds', s)) IS NULL;
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
             WHERE conrelid = format('%I.entitlement_refunds', s)::regclass
               AND conname = 'entitlement_refunds_entitlement_id_stripe_refund_id_key'
        ) THEN
            RAISE EXCEPTION '%.entitlement_refunds does not record a refund once per entitlement', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
