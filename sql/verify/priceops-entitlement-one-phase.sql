-- ABOUTME: Verify every schema's entitlements carry their offer and the one-schedule-phase exclusion.
-- ABOUTME: Checked per schema, because a tenant's entitlements live in its own schema.

-- Verify registry:priceops-entitlement-one-phase on pg

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
        EXECUTE format('SELECT offer_id FROM %I.entitlements WHERE false', s);
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
             WHERE conrelid = format('%I.entitlements', s)::regclass
               AND conname = 'entitlements_one_schedule_phase' AND contype = 'x'
        ) THEN
            RAISE EXCEPTION 'entitlements_one_schedule_phase missing in schema %', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
