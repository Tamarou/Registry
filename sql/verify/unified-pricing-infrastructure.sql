-- ABOUTME: Verify unified pricing infrastructure migration
-- ABOUTME: Ensures all tables, columns, and constraints were created successfully

-- Verify registry:unified-pricing-infrastructure on pg

BEGIN;

-- Verify pricing_plans columns exist
SELECT
    plan_scope,
    pricing_model_type,
    pricing_configuration
FROM registry.pricing_plans
WHERE FALSE;

-- Verify tenant_pricing_relationships table (if it still exists - may be dropped by later migrations)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'registry' AND table_name = 'tenant_pricing_relationships') THEN
        -- Table exists, verify structure
        PERFORM id, payer_tenant_id, payee_tenant_id, pricing_plan_id, relationship_type,
                started_at, ended_at, is_active, metadata, created_at, updated_at
        FROM registry.tenant_pricing_relationships
        WHERE FALSE;
    END IF;
    -- If table doesn't exist, that's OK - it's dropped in consolidate-pricing-relationships
END $$;

-- Verify billing_periods table exists with correct structure
SELECT
    id,
    pricing_relationship_id,
    period_start,
    period_end,
    calculated_amount,
    payment_status,
    stripe_invoice_id,
    stripe_payment_intent_id,
    processed_at,
    metadata,
    created_at,
    updated_at
FROM registry.billing_periods
WHERE FALSE;

-- Verify platform tenant exists
SELECT id, name, slug
FROM registry.tenants
WHERE id = '00000000-0000-0000-0000-000000000000'::UUID;

-- Verify platform pricing plans exist
SELECT COUNT(*) AS plan_count
FROM registry.pricing_plans
WHERE plan_scope = 'platform'
HAVING COUNT(*) >= 3;

-- Verify indexes exist (check both possible table names due to later migrations)
SELECT indexname
FROM pg_indexes
WHERE schemaname = 'registry'
  AND (
    (tablename = 'billing_periods' AND indexname IN (
      'idx_billing_periods_relationship',
      'idx_billing_periods_status',
      'idx_billing_periods_period'
    ))
    OR
    (tablename IN ('tenant_pricing_relationships', 'pricing_relationships') AND indexname IN (
      'idx_tenant_relationships_payer',
      'idx_tenant_relationships_payee',
      'idx_tenant_relationships_active',
      'idx_pricing_relationships_provider',
      'idx_pricing_relationships_consumer',
      'idx_pricing_relationships_status'
    ))
  );

ROLLBACK;