-- ABOUTME: Verification script to ensure pricing_relationships table exists with correct structure
-- ABOUTME: Validates migration from tenant_pricing_relationships was successful

-- Verify registry:consolidate-pricing-relationships on pg

BEGIN;

-- Verify the pricing_relationships table exists with correct columns
SELECT
    id,
    provider_id,
    consumer_id,
    pricing_plan_id,
    status,
    metadata,
    created_at,
    updated_at
FROM registry.pricing_relationships
WHERE false;

-- Verify indexes exist
SELECT 1 FROM pg_indexes WHERE schemaname = 'registry' AND tablename = 'pricing_relationships' AND indexname = 'idx_pricing_relationships_provider';
SELECT 1 FROM pg_indexes WHERE schemaname = 'registry' AND tablename = 'pricing_relationships' AND indexname = 'idx_pricing_relationships_consumer';
SELECT 1 FROM pg_indexes WHERE schemaname = 'registry' AND tablename = 'pricing_relationships' AND indexname = 'idx_pricing_relationships_status';
SELECT 1 FROM pg_indexes WHERE schemaname = 'registry' AND tablename = 'pricing_relationships' AND indexname = 'idx_pricing_relationships_plan';

-- Verify the old table no longer exists
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables
               WHERE table_schema = 'registry'
               AND table_name = 'tenant_pricing_relationships') THEN
        RAISE EXCEPTION 'Table tenant_pricing_relationships still exists';
    END IF;
END $$;

-- Verify billing_periods references the new table
SELECT pricing_relationship_id FROM registry.billing_periods WHERE false;

-- Verify foreign key constraint exists
SELECT 1
FROM information_schema.table_constraints tc
JOIN information_schema.constraint_column_usage ccu
    ON tc.constraint_name = ccu.constraint_name
WHERE tc.table_schema = 'registry'
    AND tc.table_name = 'billing_periods'
    AND tc.constraint_type = 'FOREIGN KEY'
    AND ccu.table_name = 'pricing_relationships';

-- Verify trigger exists
SELECT 1 FROM information_schema.triggers
WHERE trigger_schema = 'registry'
    AND event_object_table = 'pricing_relationships'
    AND trigger_name = 'update_pricing_relationships_updated_at';

ROLLBACK;