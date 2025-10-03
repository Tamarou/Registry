-- ABOUTME: Verify pricing validation trigger handles NULL values gracefully
-- ABOUTME: Ensures trigger doesn't cause connection termination with minimal plans

-- Verify registry:fix-pricing-validation-trigger on pg

BEGIN;

-- Check that the function exists
SELECT pg_get_functiondef(oid)
FROM pg_proc
WHERE proname = 'validate_pricing_resources'
  AND pronamespace = 'registry'::regnamespace;

-- Check that the trigger exists
SELECT 1 FROM pg_trigger
WHERE tgname = 'validate_pricing_resources_trigger'
  AND tgrelid = 'registry.pricing_plans'::regclass;

-- Test that we can create a minimal pricing plan without errors
-- This should not cause a connection termination
INSERT INTO registry.pricing_plans (plan_name, amount)
VALUES ('Test Plan', 100.00);

-- Clean up the test record
DELETE FROM registry.pricing_plans WHERE plan_name = 'Test Plan';

ROLLBACK;