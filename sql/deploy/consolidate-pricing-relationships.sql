-- ABOUTME: Migration to consolidate tenant_pricing_relationships into unified pricing_relationships
-- ABOUTME: Creates universal table that handles platform, B2C, and B2B relationships

-- Deploy registry:consolidate-pricing-relationships to pg
-- requires: unified-pricing-infrastructure

BEGIN;

-- Create the new unified pricing_relationships table
CREATE TABLE IF NOT EXISTS registry.pricing_relationships (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    provider_id UUID NOT NULL REFERENCES registry.tenants(id),
    consumer_id UUID NOT NULL REFERENCES registry.users(id),
    pricing_plan_id UUID NOT NULL REFERENCES registry.pricing_plans(id),
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('pending', 'active', 'suspended', 'cancelled')),
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create indexes for performance
CREATE INDEX idx_pricing_relationships_provider ON registry.pricing_relationships(provider_id);
CREATE INDEX idx_pricing_relationships_consumer ON registry.pricing_relationships(consumer_id);
CREATE INDEX idx_pricing_relationships_status ON registry.pricing_relationships(status) WHERE status IN ('active', 'pending');
CREATE INDEX idx_pricing_relationships_plan ON registry.pricing_relationships(pricing_plan_id);

-- First, create system admin users for tenants that don't have them
DO $$
DECLARE
    tenant_record RECORD;
    new_user_id UUID;
BEGIN
    FOR tenant_record IN
        SELECT DISTINCT tpr.payer_tenant_id, t.name
        FROM registry.tenant_pricing_relationships tpr
        JOIN registry.tenants t ON t.id = tpr.payer_tenant_id
        WHERE NOT EXISTS (
            SELECT 1 FROM registry.users u
            JOIN registry.tenant_users tu ON tu.user_id = u.id
            WHERE tu.tenant_id = tpr.payer_tenant_id
            AND tu.is_primary = true
        )
    LOOP
        -- Create a system admin user for this tenant
        new_user_id := gen_random_uuid();

        INSERT INTO registry.users (id, username, passhash)
        VALUES (
            new_user_id,
            'admin_' || replace(tenant_record.payer_tenant_id::text, '-', ''),
            '$2b$12$DummyHashForSystemUser'  -- System users can't login directly
        );

        INSERT INTO registry.user_profiles (user_id, email, name)
        VALUES (
            new_user_id,
            'admin+' || tenant_record.payer_tenant_id || '@registry.system',
            COALESCE(tenant_record.name, 'Unknown Tenant') || ' Admin'
        );

        INSERT INTO registry.tenant_users (tenant_id, user_id, is_primary)
        VALUES (
            tenant_record.payer_tenant_id,
            new_user_id,
            true
        );
    END LOOP;
END $$;

-- Now migrate existing data from tenant_pricing_relationships
-- Map payer_tenant -> consumer (through tenant admin user)
-- Map payee_tenant -> provider
INSERT INTO registry.pricing_relationships (
    id,
    provider_id,
    consumer_id,
    pricing_plan_id,
    status,
    metadata,
    created_at,
    updated_at
)
SELECT
    tpr.id,
    tpr.payee_tenant_id as provider_id,
    (SELECT u.id FROM registry.users u
     JOIN registry.tenant_users tu ON tu.user_id = u.id
     WHERE tu.tenant_id = tpr.payer_tenant_id
     AND tu.is_primary = true
     ORDER BY u.created_at ASC
     LIMIT 1) as consumer_id,
    tpr.pricing_plan_id,
    CASE
        WHEN tpr.is_active = true AND tpr.ended_at IS NULL THEN 'active'
        WHEN tpr.is_active = false AND tpr.ended_at IS NOT NULL THEN 'cancelled'
        WHEN tpr.is_active = false THEN 'suspended'
        ELSE 'active'
    END as status,
    jsonb_build_object(
        'migrated_from', 'tenant_pricing_relationships',
        'original_id', tpr.id,
        'relationship_type', tpr.relationship_type,
        'started_at', tpr.started_at,
        'ended_at', tpr.ended_at,
        'original_metadata', tpr.metadata
    ) as metadata,
    tpr.created_at,
    tpr.updated_at
FROM registry.tenant_pricing_relationships tpr;

-- Update billing_periods to reference the new table
-- First, add the new column
ALTER TABLE registry.billing_periods
    ADD COLUMN IF NOT EXISTS pricing_relationship_id_new UUID REFERENCES registry.pricing_relationships(id);

-- Copy the existing relationship IDs
UPDATE registry.billing_periods bp
SET pricing_relationship_id_new = pr.id
FROM registry.pricing_relationships pr
WHERE bp.pricing_relationship_id = pr.id;

-- Drop the old foreign key constraint
ALTER TABLE registry.billing_periods
    DROP CONSTRAINT IF EXISTS billing_periods_pricing_relationship_id_fkey;

-- Drop the old column
ALTER TABLE registry.billing_periods
    DROP COLUMN IF EXISTS pricing_relationship_id;

-- Rename the new column to the original name
ALTER TABLE registry.billing_periods
    RENAME COLUMN pricing_relationship_id_new TO pricing_relationship_id;

-- Re-add the NOT NULL constraint
ALTER TABLE registry.billing_periods
    ALTER COLUMN pricing_relationship_id SET NOT NULL;

-- Drop the old tenant_pricing_relationships table
DROP TABLE IF EXISTS registry.tenant_pricing_relationships CASCADE;

-- Add trigger for updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_pricing_relationships_updated_at
    BEFORE UPDATE ON registry.pricing_relationships
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Grant permissions (web role may not exist in test environment)
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'web') THEN
        GRANT SELECT, INSERT, UPDATE ON registry.pricing_relationships TO web;
        GRANT USAGE ON SEQUENCE registry.pricing_relationships_id_seq TO web;
    END IF;
END $$;

COMMIT;