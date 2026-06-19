-- ABOUTME: Verify the tenants.platform_pricing_plan_id column exists.
-- ABOUTME: Asserts the FK column was added and is queryable.

-- Verify registry:tenant-platform-pricing-plan on pg

BEGIN;

SELECT 1/COUNT(*) FROM information_schema.columns
 WHERE table_schema = 'registry'
   AND table_name = 'tenants'
   AND column_name = 'platform_pricing_plan_id';

ROLLBACK;
