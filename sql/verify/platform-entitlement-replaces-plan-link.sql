-- ABOUTME: Verify the plan link is gone and every payments table stamps the platform offer version and plan.
-- ABOUTME: A link left behind would be a second source for the fee beside the tenant's platform entitlement.

-- Verify registry:platform-entitlement-replaces-plan-link on pg

BEGIN;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'registry' AND table_name = 'tenants'
                  AND column_name = 'platform_pricing_plan_id') THEN
        RAISE EXCEPTION 'registry.tenants still has platform_pricing_plan_id';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_name = 'payments' AND column_name = 'platform_pricing_plan_id') THEN
        RAISE EXCEPTION 'a payments table still stamps platform_pricing_plan_id';
    END IF;
END $$;

SELECT platform_offer_version_id, platform_payment_plan_id FROM registry.payments WHERE FALSE;

ROLLBACK;
