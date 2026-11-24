-- ABOUTME: Drop the plan-rate CHECK from every schema's pricing_plans.
-- ABOUTME: A rate written in SQL is then checked only by PricingPlan->create, and not at all if it bypasses it.

-- Revert registry:pricing-plan-rate-check from pg

BEGIN;

SET client_min_messages = 'warning';

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.pricing_plans', s)) IS NULL;
        EXECUTE format(
            'ALTER TABLE %I.pricing_plans DROP CONSTRAINT IF EXISTS pricing_plans_percentage_rate_check', s );
    END LOOP;
END $$;

COMMIT;
