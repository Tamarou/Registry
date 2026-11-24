-- ABOUTME: Verify no platform-scope plan is marked default, and the deleted rows are kept for the revert.
-- ABOUTME: Fails by division by zero if a Free plan row remains.

-- Verify registry:remove-free-platform-plan on pg

BEGIN;

SELECT 1/(COUNT(*) = 0)::int FROM registry.pricing_plans
 WHERE plan_scope = 'platform' AND metadata->>'default' = 'true';

SELECT id FROM public.removed_free_platform_plan WHERE FALSE;

ROLLBACK;
