-- ABOUTME: Verify the tenants.platform_pricing_plan_id column exists, until the platform entitlement replaces it.
-- ABOUTME: platform-entitlement-replaces-plan-link drops it and verifies that; asserting it here would never pass after.

-- Verify registry:tenant-platform-pricing-plan on pg

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'registry' AND table_name = 'tenants'
                      AND column_name = 'platform_pricing_plan_id')
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns
                        WHERE table_schema = 'registry' AND table_name = 'payments'
                          AND column_name = 'platform_offer_version_id') THEN
        RAISE EXCEPTION 'registry.tenants has no platform_pricing_plan_id';
    END IF;
END $$;

ROLLBACK;
