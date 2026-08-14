-- ABOUTME: Stop offering tenant plans that have no resolvable revenue-share rate.
-- ABOUTME: A tenant on such a plan cannot take payments at all, so it must not be selectable.

-- Deploy registry:suspend-rateless-tenant-plans to pg
-- requires: create-default-pricing-relationships

BEGIN;

-- create-default-pricing-relationships makes every tenant-scoped plan
-- selectable, including ones that carry no revenue-share rate. The fee resolver
-- (Registry::PriceOps::RevenueShare) dies rather than guess a rate, so a tenant
-- who picks such a plan has every enrollment charge fail.
--
-- Today this is "Registry Standard - $200/month": pricing_model_type 'fixed',
-- amount 200.00 (dollars, not a rate), no 'percentage' key. The predicate is
-- written against the rate rather than the plan name so a future rateless plan
-- cannot quietly become selectable.
--
-- 'suspended', not 'cancelled': the plan is pulled from the signup menu pending
-- a pricing decision, not retired. Restoring it is the revert plus a rate.
UPDATE registry.pricing_relationships pr
   SET status     = 'suspended',
       metadata   = pr.metadata
                  || '{"suspended_by_migration": "suspend-rateless-tenant-plans"}'::jsonb,
       updated_at = CURRENT_TIMESTAMP
  FROM registry.pricing_plans p
 WHERE p.id = pr.pricing_plan_id
   AND pr.status = 'active'
   AND p.plan_scope = 'tenant'
   AND COALESCE(
         p.pricing_configuration->>'percentage',
         CASE WHEN p.pricing_model_type = 'percentage' THEN p.amount::text END
       ) IS NULL;

COMMIT;
