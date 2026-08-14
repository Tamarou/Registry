-- ABOUTME: Verify no active platform-offered relationship offers a tenant-scoped hybrid plan.
-- ABOUTME: True at this point in the plan and at the end of it, including after Leg 9b.

-- Verify registry:retire-registry-plus-plan on pg

BEGIN;

DO $$
BEGIN
    -- Leg 9b drops pricing_relationships AND pricing_plans.plan_type/plan_scope
    -- (spec :3854-3855).  Every verify runs again against the final schema
    -- (t/database/migration-verification.t:26), so this one goes vacuous instead
    -- of erroring.  Check the columns as well as the table: if Leg 9b drops them
    -- in separate changes, there is a point where the table is still here and the
    -- columns are not, and a table-only guard fails there.
    IF to_regclass('registry.pricing_relationships') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'registry'
              AND table_name   = 'pricing_plans'
              AND column_name IN ('plan_type', 'plan_scope')
            HAVING count(*) = 2
       )
    THEN
        RETURN;
    END IF;

    -- All three conditions match the deploy, and all three are load-bearing.
    -- Drop plan_scope and this asserts no tenant ever authors a customer-scoped
    -- hybrid plan; drop provider_id and it asserts no tenant ever resells a
    -- tenant-scoped one.  Either is an assertion a tenant can falsify from the
    -- product, turning CI permanently red with no code change that fixes it.
    IF EXISTS (
        SELECT 1
          FROM registry.pricing_relationships pr
          JOIN registry.pricing_plans pp ON pp.id = pr.pricing_plan_id
         WHERE pp.plan_type   = 'hybrid'
           AND pp.plan_scope  = 'tenant'
           AND pr.provider_id = '00000000-0000-0000-0000-000000000000'
           AND pr.status      = 'active'
    ) THEN
        RAISE EXCEPTION 'the platform still offers a tenant-scoped hybrid pricing plan on an active relationship';
    END IF;
END $$;

ROLLBACK;
