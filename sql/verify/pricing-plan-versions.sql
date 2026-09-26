-- ABOUTME: Verify every schema holding pricing plans carries versioning, and charges carry a plan.
-- ABOUTME: Checked across tenants, because registry alone is not where the charges live.

-- Verify registry:pricing-plan-versions on pg

BEGIN;

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        IF to_regclass(format('%I.pricing_plans', s)) IS NOT NULL THEN
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                 WHERE table_schema = s AND table_name = 'pricing_plans'
                   AND column_name = 'plan_family_id'
            ) THEN
                RAISE EXCEPTION 'pricing_plans.plan_family_id missing in schema %', s;
            END IF;

            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                 WHERE table_schema = s AND table_name = 'pricing_plans'
                   AND column_name = 'version'
            ) THEN
                RAISE EXCEPTION 'pricing_plans.version missing in schema %', s;
            END IF;

            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                 WHERE table_schema = s AND table_name = 'pricing_plans'
                   AND column_name = 'superseded_at'
            ) THEN
                RAISE EXCEPTION 'pricing_plans.superseded_at missing in schema %', s;
            END IF;

            -- The constraint is the point, not just the column: without it
            -- "the current version" has no single answer.
            IF NOT EXISTS (
                SELECT 1 FROM pg_indexes
                 WHERE schemaname = s AND tablename = 'pricing_plans'
                   AND indexname = 'pricing_plans_one_current_per_family'
            ) THEN
                RAISE EXCEPTION 'pricing_plans_one_current_per_family missing in schema %', s;
            END IF;
        END IF;

        IF to_regclass(format('%I.payment_items', s)) IS NOT NULL THEN
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                 WHERE table_schema = s AND table_name = 'payment_items'
                   AND column_name = 'pricing_plan_id'
            ) THEN
                RAISE EXCEPTION 'payment_items.pricing_plan_id missing in schema %', s;
            END IF;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
