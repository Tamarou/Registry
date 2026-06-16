-- ABOUTME: Revert the tenants.platform_pricing_plan_id FK column.
-- ABOUTME: Drops the column added by the deploy migration.

-- Revert registry:tenant-platform-pricing-plan from pg

BEGIN;

ALTER TABLE registry.tenants DROP COLUMN IF EXISTS platform_pricing_plan_id;

COMMIT;
