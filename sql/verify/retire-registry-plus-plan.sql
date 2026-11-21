-- ABOUTME: Verify no active pricing relationship offers a tenant-scoped hybrid plan.
-- ABOUTME: True at this point in the plan and at the end of it, including after Leg 9b.

-- Verify registry:retire-registry-plus-plan on pg

BEGIN;

DO $$
BEGIN
    -- Leg 9b drops pricing_relationships.  Every verify runs again against the
    -- final schema (t/database/migration-verification.t:26), so this one goes
    -- vacuous instead of erroring on a missing table.
    IF to_regclass('registry.pricing_relationships') IS NULL THEN
        RETURN;
    END IF;

    -- plan_scope = 'tenant' matches the deploy.  Unguarded, this asserts that no
    -- tenant ever authors a customer-scoped hybrid plan -- an assertion a tenant
    -- can falsify from the product, turning CI permanently red.
    IF EXISTS (
        SELECT 1
          FROM registry.pricing_relationships pr
          JOIN registry.pricing_plans pp ON pp.id = pr.pricing_plan_id
         WHERE pp.plan_type  = 'hybrid'
           AND pp.plan_scope = 'tenant'
           AND pr.status     = 'active'
    ) THEN
        RAISE EXCEPTION 'a tenant-scoped hybrid pricing plan is still offered by an active relationship';
    END IF;
END $$;

ROLLBACK;
