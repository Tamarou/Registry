-- ABOUTME: Revert script to restore tenant_pricing_relationships from unified pricing_relationships
-- ABOUTME: Reconstructs original table structure and migrates data back

-- Revert registry:consolidate-pricing-relationships from pg

BEGIN;

-- Recreate the original tenant_pricing_relationships table
CREATE TABLE IF NOT EXISTS registry.tenant_pricing_relationships (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    payer_tenant_id UUID NOT NULL REFERENCES registry.tenants(id),
    payee_tenant_id UUID NOT NULL REFERENCES registry.tenants(id),
    pricing_plan_id UUID NOT NULL REFERENCES registry.pricing_plans(id),
    relationship_type VARCHAR(50) NOT NULL
        CHECK (relationship_type IN ('platform_fee', 'service_fee', 'revenue_share', 'partnership')),
    started_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ended_at TIMESTAMP WITH TIME ZONE,
    is_active BOOLEAN DEFAULT true,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Recreate indexes
CREATE INDEX idx_tenant_relationships_payer ON registry.tenant_pricing_relationships(payer_tenant_id);
CREATE INDEX idx_tenant_relationships_payee ON registry.tenant_pricing_relationships(payee_tenant_id);
CREATE INDEX idx_tenant_relationships_active ON registry.tenant_pricing_relationships(is_active) WHERE is_active = true;

-- Migrate data back from pricing_relationships
INSERT INTO registry.tenant_pricing_relationships (
    id,
    payer_tenant_id,
    payee_tenant_id,
    pricing_plan_id,
    relationship_type,
    started_at,
    ended_at,
    is_active,
    metadata,
    created_at,
    updated_at
)
SELECT
    pr.id,
    COALESCE(u.tenant_id, '00000000-0000-0000-0000-000000000000'::UUID) as payer_tenant_id,
    pr.provider_id as payee_tenant_id,
    pr.pricing_plan_id,
    COALESCE(
        pr.metadata->>'relationship_type',
        CASE
            WHEN pr.provider_id = '00000000-0000-0000-0000-000000000000'::UUID THEN 'platform_fee'
            ELSE 'service_fee'
        END
    ) as relationship_type,
    COALESCE(
        (pr.metadata->>'started_at')::TIMESTAMP WITH TIME ZONE,
        pr.created_at
    ) as started_at,
    (pr.metadata->>'ended_at')::TIMESTAMP WITH TIME ZONE as ended_at,
    pr.status IN ('active', 'pending') as is_active,
    COALESCE(
        pr.metadata->'original_metadata',
        pr.metadata
    ) as metadata,
    pr.created_at,
    pr.updated_at
FROM registry.pricing_relationships pr
JOIN registry.users u ON pr.consumer_id = u.id
WHERE pr.metadata->>'migrated_from' = 'tenant_pricing_relationships'
   OR pr.provider_id = '00000000-0000-0000-0000-000000000000'::UUID
   OR u.tenant_id IS NOT NULL;

-- Update billing_periods to reference the old table
ALTER TABLE registry.billing_periods
    ADD COLUMN IF NOT EXISTS pricing_relationship_id_old UUID REFERENCES registry.tenant_pricing_relationships(id);

UPDATE registry.billing_periods bp
SET pricing_relationship_id_old = tpr.id
FROM registry.tenant_pricing_relationships tpr
WHERE bp.pricing_relationship_id = tpr.id;

ALTER TABLE registry.billing_periods
    DROP CONSTRAINT IF EXISTS billing_periods_pricing_relationship_id_fkey;

ALTER TABLE registry.billing_periods
    DROP COLUMN IF EXISTS pricing_relationship_id;

ALTER TABLE registry.billing_periods
    RENAME COLUMN pricing_relationship_id_old TO pricing_relationship_id;

ALTER TABLE registry.billing_periods
    ALTER COLUMN pricing_relationship_id SET NOT NULL;

-- Drop the unified pricing_relationships table
DROP TABLE IF EXISTS registry.pricing_relationships CASCADE;

-- Recreate the trigger for updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_tenant_pricing_relationships_updated_at
    BEFORE UPDATE ON registry.tenant_pricing_relationships
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Grant permissions (web role may not exist in test environment)
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'web') THEN
        GRANT SELECT, INSERT, UPDATE ON registry.tenant_pricing_relationships TO web;
    END IF;
END $$;

COMMIT;