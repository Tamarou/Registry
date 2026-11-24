-- ABOUTME: Verify every schema's offer versions carry their price, units, booking cap, payment plans, policies and conditions.
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
            'SELECT price_cents, units_per_acceptance, per_booking_cap, policies, conditions FROM %I.offer_versions WHERE false', s);
        EXECUTE format(
            'SELECT offer_version_id, id, kind, fraction FROM %I.offer_version_payment_plans WHERE false', s);
        -- The trigger is the enforcement; without it published plans are editable.
        IF NOT EXISTS (
            SELECT 1 FROM pg_trigger
             WHERE tgrelid = format('%I.offer_version_payment_plans', s)::regclass
               AND tgname = 'offer_version_payment_plans_immutable'
        ) THEN
            RAISE EXCEPTION 'offer_version_payment_plans_immutable trigger missing in schema %', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
