-- ABOUTME: Verify the platform tenant links no platform pricing plan to itself.
-- ABOUTME: A link here would have the platform charge itself a share of its own sales.

-- Verify registry:platform-tenant-unlinks-solo on pg

BEGIN;

DO $$
BEGIN
    -- platform-entitlement-replaces-plan-link drops the column; nested, so
    -- the query naming it is planned only while it exists.
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'registry' AND table_name = 'tenants'
                  AND column_name = 'platform_pricing_plan_id') THEN
        IF EXISTS (SELECT 1 FROM registry.tenants
                    WHERE id = '00000000-0000-0000-0000-000000000000'
                      AND platform_pricing_plan_id IS NOT NULL) THEN
            RAISE EXCEPTION 'the platform tenant still links a platform pricing plan';
        END IF;
    END IF;
END $$;

ROLLBACK;
