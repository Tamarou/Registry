-- ABOUTME: Revert unified pricing infrastructure migration
-- ABOUTME: Removes tenant-to-tenant pricing tables and restores original state

-- Revert registry:unified-pricing-infrastructure from pg

BEGIN;

-- Drop triggers
DROP TRIGGER IF EXISTS update_tenant_pricing_relationships_updated_at ON registry.tenant_pricing_relationships;
DROP TRIGGER IF EXISTS update_billing_periods_updated_at ON registry.billing_periods;

-- Drop the update function if no other triggers use it
DROP FUNCTION IF EXISTS update_updated_at_column();

-- Drop billing periods table
DROP TABLE IF EXISTS registry.billing_periods;

-- Drop tenant pricing relationships table
DROP TABLE IF EXISTS registry.tenant_pricing_relationships;

-- Remove platform pricing plans
DELETE FROM registry.pricing_plans
WHERE offering_tenant_id = '00000000-0000-0000-0000-000000000000'::UUID;

-- Remove platform tenant (only if it was created by this migration)
DELETE FROM registry.tenants
WHERE id = '00000000-0000-0000-0000-000000000000'::UUID
  AND NOT EXISTS (
    SELECT 1 FROM registry.users
    WHERE tenant_id = '00000000-0000-0000-0000-000000000000'::UUID
  );

-- Drop the unified pricing_plans table from registry schema
DROP TABLE IF EXISTS registry.pricing_plans;

COMMIT;