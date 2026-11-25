-- ABOUTME: A Stripe refund is recorded once per entitlement, not once per schema, so one refund can cover several.
-- ABOUTME: A refund of a payment that bought several entitlements is shared among them, each keeping its part.

-- Deploy registry:entitlement-refunds-per-entitlement to pg
-- requires: holds-placed-at

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
                DROP CONSTRAINT entitlement_refunds_stripe_refund_id_key,
                ADD CONSTRAINT entitlement_refunds_entitlement_id_stripe_refund_id_key
                    UNIQUE (entitlement_id, stripe_refund_id)
        $f$, s);
    END LOOP;
END $$;

COMMIT;
