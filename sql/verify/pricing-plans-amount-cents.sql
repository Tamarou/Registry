-- ABOUTME: Verify pricing_plans money is integer cents in registry and every tenant schema.
-- ABOUTME: Also asserts no percentage plan smuggled its rate into the money column.

-- Verify registry:pricing-plans-amount-cents on pg

BEGIN;

DO $$
DECLARE
    s        name;
    bad_type text;
    strays   INT;
BEGIN
    SELECT data_type INTO bad_type
      FROM information_schema.columns
     WHERE table_schema = 'registry' AND table_name = 'pricing_plans'
       AND column_name = 'amount_cents';

    IF bad_type IS DISTINCT FROM 'integer' THEN
        RAISE EXCEPTION 'registry.pricing_plans.amount_cents is %, expected integer',
            COALESCE(bad_type, 'missing');
    END IF;

    PERFORM 1 FROM information_schema.columns
      WHERE table_schema = 'registry' AND table_name = 'pricing_plans'
        AND column_name = 'amount';
    IF FOUND THEN
        RAISE EXCEPTION 'registry.pricing_plans still has the dollars column';
    END IF;

    -- A percentage plan has no dollar amount. A non-zero value here means a
    -- rate was multiplied into the money column, and every charge on that plan
    -- would carry the wrong application fee.
    SELECT COUNT(*) INTO strays
      FROM registry.pricing_plans
     WHERE pricing_model_type = 'percentage' AND amount_cents <> 0;
    IF strays > 0 THEN
        RAISE EXCEPTION '% percentage plan(s) carry a non-zero amount_cents', strays;
    END IF;

    -- Every existing tenant must have been converted too; one left behind would
    -- charge in dollars against code that now reads cents.
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        -- Skip tenants that don't have their own schema (e.g. registry-platform)
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );

        PERFORM 1 FROM information_schema.columns
          WHERE table_schema = s AND table_name = 'pricing_plans'
            AND column_name = 'amount_cents';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'tenant schema % has no amount_cents', s;
        END IF;

        PERFORM 1 FROM information_schema.columns
          WHERE table_schema = s AND table_name = 'pricing_plans'
            AND column_name = 'amount';
        IF FOUND THEN
            RAISE EXCEPTION 'tenant schema % still has the dollars column', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
