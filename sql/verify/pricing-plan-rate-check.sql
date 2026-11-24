-- ABOUTME: Verify the plan-rate CHECK exists on registry.pricing_plans.
-- ABOUTME: Without it a rate written in SQL can break checkout at the payment intent.

-- Verify registry:pricing-plan-rate-check on pg

BEGIN;

SELECT 1/count(*) FROM pg_constraint
 WHERE conrelid = 'registry.pricing_plans'::regclass
   AND conname = 'pricing_plans_percentage_rate_check'
   -- The rule, not just the name: an earlier version required no rate on a
   -- percentage or hybrid plan, and a database deployed with it must not pass.
   AND pg_get_constraintdef(oid) LIKE '%''hybrid''%'
   AND pg_get_constraintdef(oid) LIKE '%round(%, 4)%';

ROLLBACK;
