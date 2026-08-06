-- ABOUTME: Restore the dollars column on pricing_plans.
-- ABOUTME: Percentage rows recover their rate from pricing_configuration, not from cents.

-- Revert registry:pricing-plans-amount-cents from pg

BEGIN;

SET client_min_messages = 'warning';

-- Percentage rows held a rate here, not money, and the deploy set their
-- amount_cents to 0. Recovering that rate from 0 is impossible, so read it back
-- out of pricing_configuration -- the copy the deploy deliberately preserved.
-- A percentage row with no rate in config had nothing to restore in the first
-- place and lands on 0, which is what the old fallback would have resolved to.

ALTER TABLE registry.pricing_plans
    ADD COLUMN IF NOT EXISTS amount DECIMAL(10,2) NOT NULL DEFAULT 0;

UPDATE registry.pricing_plans
   SET amount = CASE
         WHEN pricing_model_type = 'percentage'
           THEN COALESCE((pricing_configuration->>'percentage')::DECIMAL(10,2), 0)
         ELSE amount_cents::DECIMAL / 100
       END;

ALTER TABLE registry.pricing_plans ALTER COLUMN amount DROP DEFAULT;
ALTER TABLE registry.pricing_plans DROP COLUMN amount_cents;

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
                ADD COLUMN IF NOT EXISTS amount DECIMAL(10,2) NOT NULL DEFAULT 0', s);

        EXECUTE format(
            'UPDATE %I.pricing_plans
                SET amount = CASE
                      WHEN pricing_model_type = ''percentage''
                        THEN COALESCE((pricing_configuration->>''percentage'')::DECIMAL(10,2), 0)
                      ELSE amount_cents::DECIMAL / 100
                    END', s);

        EXECUTE format('ALTER TABLE %I.pricing_plans ALTER COLUMN amount DROP DEFAULT', s);
        EXECUTE format('ALTER TABLE %I.pricing_plans DROP COLUMN amount_cents', s);
    END LOOP;
END $$;

COMMIT;
