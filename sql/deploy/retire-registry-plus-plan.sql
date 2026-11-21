-- ABOUTME: Stop offering the seeded Registry Plus hybrid plan.
-- ABOUTME: Nothing can price a hybrid plan, so an active offer is a plan that cannot bill.

-- Deploy registry:retire-registry-plus-plan to pg
-- requires: suspend-rateless-tenant-plans

BEGIN;

SET client_min_messages = 'warning';

-- Scoped to tenant plans, matching suspend-rateless-tenant-plans:29.  plan_scope
-- defaults to 'customer' and a tenant can author a customer-scoped hybrid plan
-- through PricingPlanBasics; that is the tenant's pricing, not the platform's
-- signup menu, and this change has no business suspending it.
--
-- Stamp each row so the revert restores exactly what this change suspended and
-- leaves rows suspended for other reasons alone.  metadata is nullable, and
-- NULL || jsonb is NULL: without the COALESCE a row with no metadata would be
-- suspended without a stamp, and the revert would never find it again.
UPDATE registry.pricing_relationships pr
   SET status     = 'suspended',
       metadata   = COALESCE(pr.metadata, '{}'::jsonb)
                  || '{"suspended_by_migration": "retire-registry-plus-plan"}'::jsonb,
       updated_at = CURRENT_TIMESTAMP
  FROM registry.pricing_plans pp
 WHERE pp.id = pr.pricing_plan_id
   AND pp.plan_type = 'hybrid'
   AND pp.plan_scope = 'tenant'
   AND pr.status = 'active';

COMMIT;
