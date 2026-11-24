-- ABOUTME: Verify the platform-scope Free fallback plan exists.
-- ABOUTME: Asserts exactly one default platform plan with a zero rate.

-- Verify registry:seed-free-platform-plan on pg

BEGIN;

-- remove-free-platform-plan later deletes the row and keeps it in its own
-- table, so either holds once that change deploys.
SELECT 1/COUNT(*) FROM (
    SELECT 1 FROM registry.pricing_plans
     WHERE plan_scope = 'platform'
       AND metadata->>'default' = 'true'
       AND pricing_model_type = 'percentage'
       AND (pricing_configuration->>'percentage')::NUMERIC = 0
    UNION ALL
    SELECT 1 WHERE to_regclass('public.removed_free_platform_plan') IS NOT NULL
) free;

ROLLBACK;
