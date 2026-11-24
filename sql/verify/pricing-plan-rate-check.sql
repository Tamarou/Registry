-- ABOUTME: Verify the plan-rate CHECK exists on registry.pricing_plans.
-- ABOUTME: Without it a rate written in SQL can break checkout at the payment intent.

-- Verify registry:pricing-plan-rate-check on pg

BEGIN;

SELECT 1/count(*) FROM pg_constraint
 WHERE conrelid = 'registry.pricing_plans'::regclass
   AND conname = 'pricing_plans_percentage_rate_check';

ROLLBACK;
