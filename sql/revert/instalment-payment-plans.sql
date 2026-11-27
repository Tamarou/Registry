-- ABOUTME: Drops the instalments plan columns, kind and missed_payment trigger in registry and every tenant schema.
-- ABOUTME: clone_schema gave tenants provisioned since deploy their own trigger function; those copies go too.

-- Revert registry:instalment-payment-plans from pg

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
        CONTINUE WHEN to_regclass(format('%I.offer_version_payment_plans', s)) IS NULL;
        EXECUTE format('DROP TRIGGER IF EXISTS offer_versions_instalments_need_missed_payment ON %I.offer_versions', s);
        -- Refused while any instalments plan remains: the revert does not guess what it should become.
        EXECUTE format($f$
            ALTER TABLE %1$I.offer_version_payment_plans
                DROP CONSTRAINT IF EXISTS offer_version_payment_plans_instalments_fields,
                DROP COLUMN IF EXISTS count,
                DROP COLUMN IF EXISTS cadence,
                DROP COLUMN IF EXISTS surcharge_pct,
                DROP CONSTRAINT offer_version_payment_plans_kind_check,
                ADD CONSTRAINT offer_version_payment_plans_kind_check
                    CHECK (kind IN ('one_time', 'percentage_of_sales'))
        $f$, s);
    END LOOP;
    -- Second pass: tenants made before deploy trigger on registry's function.
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        EXECUTE format('DROP FUNCTION IF EXISTS %I.offer_version_instalments_need_missed_payment()', s);
    END LOOP;
END $$;

COMMIT;
