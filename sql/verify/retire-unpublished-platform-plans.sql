-- ABOUTME: Verify no stamped, hybrid or rateless platform plan for tenants is current any more.
-- ABOUTME: Fails by division by zero otherwise; also checks the retired rows are kept for the revert.

-- Verify registry:retire-unpublished-platform-plans on pg

BEGIN;

SELECT 1/(COUNT(*) = 0)::int FROM registry.pricing_plans
 WHERE plan_scope = 'tenant' AND superseded_at IS NULL
   AND (metadata->>'created_by_migration' = 'seed-tier-pricing-options'
        OR plan_type = 'hybrid'
        OR pricing_configuration->>'percentage' IS NULL);

SELECT id FROM public.retired_platform_plans WHERE FALSE;

ROLLBACK;
