-- ABOUTME: Revert resource-aware pricing plans enhancements
-- ABOUTME: Removes validation triggers and indexes added for resource allocation

-- Revert registry:resource-aware-pricing-plans from pg

BEGIN;

-- Drop the validation trigger
DROP TRIGGER IF EXISTS validate_pricing_resources_trigger ON registry.pricing_plans;

-- Drop the validation function
DROP FUNCTION IF EXISTS registry.validate_pricing_resources();

-- Drop indexes
DROP INDEX IF EXISTS registry.idx_pricing_plans_scope;
DROP INDEX IF EXISTS registry.idx_pricing_plans_offering_tenant;
DROP INDEX IF EXISTS registry.idx_pricing_plans_active;

-- Remove comments (they'll revert to NULL)
COMMENT ON COLUMN registry.pricing_plans.pricing_configuration IS NULL;
COMMENT ON COLUMN registry.pricing_plans.requirements IS NULL;

COMMIT;