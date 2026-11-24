-- ABOUTME: Verify registry.tenants refuses a link to a pricing plan with no rate, while the link exists.
-- ABOUTME: Without the trigger such a link is found only when a charge dies in RevenueShare.

-- Verify registry:tenant-plan-has-rate on pg

BEGIN;

-- platform-entitlement-replaces-plan-link drops the link and this trigger with
-- it; asserting the trigger after that would make this verify unpassable.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'registry' AND table_name = 'tenants'
                  AND column_name = 'platform_pricing_plan_id')
       AND NOT EXISTS (SELECT 1 FROM pg_trigger
                        WHERE tgrelid = 'registry.tenants'::regclass
                          AND tgname = 'tenants_plan_has_rate') THEN
        RAISE EXCEPTION 'registry.tenants has no tenants_plan_has_rate trigger';
    END IF;
END $$;

ROLLBACK;
