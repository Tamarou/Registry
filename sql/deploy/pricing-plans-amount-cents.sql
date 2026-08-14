-- ABOUTME: Store pricing_plans money as integer cents and stop the column doubling as a rate.
-- ABOUTME: Backfills by pricing_model_type, because 0.02 on a percentage plan was never dollars.

-- Deploy registry:pricing-plans-amount-cents to pg
-- requires: suspend-rateless-tenant-plans

BEGIN;

SET client_min_messages = 'warning';

-- amount meant two different things depending on the row:
--
--   plan_scope='customer'                 -> dollars (a session price, 150.00)
--   pricing_model_type='fixed'/'hybrid'   -> dollars (a monthly fee, 200.00)
--   pricing_model_type='percentage'       -> a RATE FRACTION (0.02 = 2%)
--
-- Nothing could move to integer cents while that was true, and DECIMAL(10,2)
-- cannot even hold a 2.5% rate -- 0.025 rounds to 0.03. On percentage rows the
-- rate is already duplicated into pricing_configuration->>'percentage', which
-- RevenueShare reads first, so the JSONB copy is the one that matters. Keep it,
-- and let this column mean money and only money.
--
-- Percentage rows therefore backfill to 0, not to amount*100: they never had a
-- dollar amount, and 0.02 * 100 would invent a 2-cent charge.

ALTER TABLE registry.pricing_plans
    ADD COLUMN IF NOT EXISTS amount_cents INTEGER NOT NULL DEFAULT 0;

UPDATE registry.pricing_plans
   SET amount_cents = CASE
         WHEN pricing_model_type = 'percentage' THEN 0
         ELSE ROUND(amount * 100)::INTEGER
       END;

ALTER TABLE registry.pricing_plans DROP COLUMN amount;

-- clone_schema copies structure from registry at call time, so new tenants pick
-- this up on their own. Tenants that already exist do not, and a tenant left on
-- the old column would keep charging in dollars where the code now reads cents.
DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        -- Skip tenants that don't have their own schema (e.g. registry-platform)
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );

        EXECUTE format(
            'ALTER TABLE %I.pricing_plans
                ADD COLUMN IF NOT EXISTS amount_cents INTEGER NOT NULL DEFAULT 0', s);

        EXECUTE format(
            'UPDATE %I.pricing_plans
                SET amount_cents = CASE
                      WHEN pricing_model_type = ''percentage'' THEN 0
                      ELSE ROUND(amount * 100)::INTEGER
                    END', s);

        EXECUTE format('ALTER TABLE %I.pricing_plans DROP COLUMN amount', s);
    END LOOP;
END $$;

COMMIT;
