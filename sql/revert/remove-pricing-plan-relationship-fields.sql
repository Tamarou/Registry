-- ABOUTME: Revert migration that removed obsolete relationship fields from pricing_plans
-- ABOUTME: Re-adds target_tenant_id and offering_tenant_id columns if rollback is needed

-- Revert registry:remove-pricing-plan-relationship-fields from pg

BEGIN;

-- Re-add the obsolete columns
ALTER TABLE registry.pricing_plans
    ADD COLUMN IF NOT EXISTS target_tenant_id UUID REFERENCES registry.tenants(id),
    ADD COLUMN IF NOT EXISTS offering_tenant_id UUID REFERENCES registry.tenants(id);

-- Restore comment
COMMENT ON TABLE registry.pricing_plans IS NULL;

COMMIT;