-- ABOUTME: Put back one record per Stripe refund per schema.
-- ABOUTME: Fails while one refund is recorded against several entitlements, rather than drop any of them.

-- Revert registry:entitlement-refunds-per-entitlement from pg

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
        CONTINUE WHEN to_regclass(format('%I.entitlement_refunds', s)) IS NULL;
        EXECUTE format($f$
            ALTER TABLE %1$I.entitlement_refunds
                DROP CONSTRAINT entitlement_refunds_entitlement_id_stripe_refund_id_key,
                ADD CONSTRAINT entitlement_refunds_stripe_refund_id_key UNIQUE (stripe_refund_id)
        $f$, s);
    END LOOP;
END $$;

COMMIT;
