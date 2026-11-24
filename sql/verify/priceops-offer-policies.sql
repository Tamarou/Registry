-- ABOUTME: Verify every schema's offer versions carry their price, units, booking cap, payment plans and policies.
-- ABOUTME: Checked per schema, because a tenant's offers live in its own schema.

-- Verify registry:priceops-offer-policies on pg

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
            'SELECT price_cents, units_per_acceptance, per_booking_cap, policies FROM %I.offer_versions WHERE false', s);
        EXECUTE format(
            'SELECT offer_version_id, id, kind, fraction FROM %I.offer_version_payment_plans WHERE false', s);
    END LOOP;
END $$;

ROLLBACK;
