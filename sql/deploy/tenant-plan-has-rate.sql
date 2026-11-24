-- ABOUTME: A tenant can be linked only to a platform pricing plan that carries a rate.
-- ABOUTME: RevenueShare dies on a linked plan with no percentage, so the link is refused, not the charge.

-- Deploy registry:tenant-plan-has-rate to pg
-- requires: pricing-plan-rate-check

BEGIN;

SET client_min_messages = 'warning';

-- pricing-plan-rate-check lets a fixed plan have no rate, which is right for
-- the plan but not for a tenant charged a share through it. A trigger, not the
-- DAO, so raw SQL and fixtures are held to it too; a CHECK cannot read the plan.
CREATE OR REPLACE FUNCTION registry.tenant_plan_has_rate() RETURNS trigger AS $t$
BEGIN
    IF NEW.platform_pricing_plan_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM registry.pricing_plans
         WHERE id = NEW.platform_pricing_plan_id
           AND pricing_configuration->>'percentage' IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'tenant % cannot be linked to pricing plan %: it has no rate',
            NEW.slug, NEW.platform_pricing_plan_id;
    END IF;
    RETURN NEW;
END;
$t$ LANGUAGE plpgsql;

-- Refuse rather than unlink: which plan a tenant should be on is a person's call.
DO $$
BEGIN
    IF EXISTS ( SELECT 1 FROM registry.tenants t
                  JOIN registry.pricing_plans p ON p.id = t.platform_pricing_plan_id
                 WHERE p.pricing_configuration->>'percentage' IS NULL ) THEN
        RAISE EXCEPTION 'tenant-plan-has-rate: a tenant is linked to a pricing plan with no rate; relink it and deploy again';
    END IF;
END $$;

DROP TRIGGER IF EXISTS tenants_plan_has_rate ON registry.tenants;
CREATE TRIGGER tenants_plan_has_rate
    BEFORE INSERT OR UPDATE OF platform_pricing_plan_id ON registry.tenants
    FOR EACH ROW EXECUTE FUNCTION registry.tenant_plan_has_rate();

COMMIT;
