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
            --
            -- Matched by SHAPE, not by name. clone_schema builds a tenant with
            -- CREATE TABLE ... (LIKE ... INCLUDING ALL), which copies the index
            -- definition and lets Postgres auto-name it -- registry's
            -- pricing_plans_one_current_per_family arrives in a clone as
            -- pricing_plans_plan_family_id_idx. Checking the name therefore
            -- passed only for schemas this migration's own ALTER loop touched,
            -- and failed for every tenant provisioned afterwards. Since
            -- docker-entrypoint.sh treats a failed deploy as fatal, that would
            -- have refused to start production on the first boot after anybody
            -- signed up.
            IF NOT EXISTS (
                SELECT 1 FROM pg_indexes
                 WHERE schemaname = s AND tablename = 'pricing_plans'
                   AND indexdef LIKE 'CREATE UNIQUE INDEX%'
                   AND indexdef LIKE '%(plan_family_id)%'
                   AND indexdef LIKE '%WHERE (superseded_at IS NULL)'
            ) THEN
                RAISE EXCEPTION 'no unique index on pricing_plans(plan_family_id) WHERE superseded_at IS NULL in schema %', s;
            END IF;

            -- The immutability trigger is the enforcement, not the DAO. Its
            -- absence in a schema means plans there can be edited by hand.
            IF NOT EXISTS (
                SELECT 1 FROM pg_trigger t
                  JOIN pg_class c ON c.oid = t.tgrelid
                  JOIN pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname = s AND c.relname = 'pricing_plans'
                   AND t.tgname = 'pricing_plans_terms_immutable'
            ) THEN
                RAISE EXCEPTION 'pricing_plans_terms_immutable trigger missing in schema %', s;
            END IF;

            IF NOT EXISTS (
                SELECT 1 FROM pg_trigger t
                  JOIN pg_class c ON c.oid = t.tgrelid
                  JOIN pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname = s AND c.relname = 'pricing_plans'
                   AND t.tgname = 'pricing_plans_family_default'
            ) THEN
                RAISE EXCEPTION 'pricing_plans_family_default trigger missing in schema %', s;
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
