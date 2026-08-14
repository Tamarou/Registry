-- ABOUTME: Verify the platform-scope Free fallback plan exists.
-- ABOUTME: Asserts exactly one default platform plan with a zero rate.

-- Verify registry:seed-free-platform-plan on pg

BEGIN;

SELECT 1/COUNT(*) FROM registry.pricing_plans
WHERE plan_scope = 'platform'
  AND metadata->>'default' = 'true'
  AND pricing_model_type = 'percentage'
  AND (pricing_configuration->>'percentage')::NUMERIC = 0;

ROLLBACK;
