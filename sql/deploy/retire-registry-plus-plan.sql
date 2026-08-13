-- ABOUTME: Stop offering the seeded Registry Plus hybrid plan.
-- ABOUTME: Its 1% is charged but its $100/month base is collected by nothing.

-- Deploy registry:retire-registry-plus-plan to pg
-- requires: suspend-rateless-tenant-plans

BEGIN;

SET client_min_messages = 'warning';

-- Step 1's production count is a pre-flight, and a pre-flight is a time-of-check
-- window: signup is open, and a tenant can subscribe between running the query
-- and running this migration.  Re-assert it inside the transaction that does the
-- work, the way tenant-scoped-payments.sql:116-124 does.  Suspending the offer a
-- tenant is actively billed on is not a safe deletion.
--
-- The EXISTS narrows this to plans the UPDATE below will actually suspend.  A
-- pre-flight wider than the statement it guards aborts the deploy over a row the
-- change never touches: a tenant buying Registry through a reseller has a
-- tenant-scoped hybrid plan as its platform plan, that plan's offer belongs to
-- the reseller, and no edit to this file short of deleting the check would let
-- the deploy through.  Guard what you are about to change, not what it resembles.
DO $$
DECLARE
    subscribed text;
BEGIN
    SELECT string_agg(t.slug, ', ')
      INTO subscribed
      FROM registry.tenants t
      JOIN registry.pricing_plans pp ON pp.id = t.platform_pricing_plan_id
     WHERE pp.plan_type  = 'hybrid'
       AND pp.plan_scope = 'tenant'
       AND EXISTS (
           SELECT 1
             FROM registry.pricing_relationships pr
            WHERE pr.pricing_plan_id = pp.id
              AND pr.provider_id     = '00000000-0000-0000-0000-000000000000'
              AND pr.status          = 'active'
       );

    IF subscribed IS NOT NULL THEN
        RAISE EXCEPTION
            'retire-registry-plus-plan pre-flight FAILED: tenants [%] are '
            'subscribed to a tenant-scoped hybrid plan.  '
            'Migrate them off it before retiring the offer.', subscribed
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;
END $$;

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
   AND pr.provider_id = '00000000-0000-0000-0000-000000000000'
   AND pr.status = 'active';

COMMIT;
