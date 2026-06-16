-- ABOUTME: Revert the platform-scope Free fallback plan.
-- ABOUTME: Removes the default platform plan seeded by the deploy migration.

-- Revert registry:seed-free-platform-plan from pg

BEGIN;

DELETE FROM registry.pricing_plans
WHERE plan_scope = 'platform' AND metadata->>'default' = 'true';

COMMIT;
