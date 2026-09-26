-- ABOUTME: Remove pricing-plan versioning and the charge-time plan link.
-- ABOUTME: Any plan history beyond the current version becomes indistinguishable rows.

-- Revert registry:pricing-plan-versions from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

DROP TRIGGER IF EXISTS pricing_plans_family_default ON pricing_plans;

DROP INDEX IF EXISTS pricing_plans_one_current_per_family;
DROP INDEX IF EXISTS pricing_plans_family_version_key;
DROP INDEX IF EXISTS payment_items_pricing_plan_id_idx;

ALTER TABLE pricing_plans
    DROP COLUMN IF EXISTS plan_family_id,
    DROP COLUMN IF EXISTS version,
    DROP COLUMN IF EXISTS superseded_at;

ALTER TABLE payment_items DROP COLUMN IF EXISTS pricing_plan_id;

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );

        IF to_regclass(format('%I.pricing_plans', s)) IS NOT NULL THEN
            EXECUTE format(
                'DROP TRIGGER IF EXISTS pricing_plans_family_default ON %I.pricing_plans', s);
            EXECUTE format('DROP INDEX IF EXISTS %I.pricing_plans_one_current_per_family', s);
            EXECUTE format('DROP INDEX IF EXISTS %I.pricing_plans_family_version_key', s);
            EXECUTE format($f$
                ALTER TABLE %I.pricing_plans
                    DROP COLUMN IF EXISTS plan_family_id,
                    DROP COLUMN IF EXISTS version,
                    DROP COLUMN IF EXISTS superseded_at
            $f$, s);
        END IF;

        IF to_regclass(format('%I.payment_items', s)) IS NOT NULL THEN
            EXECUTE format('DROP INDEX IF EXISTS %I.payment_items_pricing_plan_id_idx', s);
            EXECUTE format(
                'ALTER TABLE %I.payment_items DROP COLUMN IF EXISTS pricing_plan_id', s);
        END IF;
    END LOOP;
END $$;

-- Last, after every trigger that referenced it -- registry's and each tenant's --
-- has been dropped. Dropping the function first fails on any deployment that
-- actually has tenant schemas, which is every real one.
DROP FUNCTION IF EXISTS registry.pricing_plan_family_default();

COMMIT;
