-- ABOUTME: Verify that obsolete relationship fields have been removed from pricing_plans
-- ABOUTME: Ensures target_tenant_id and offering_tenant_id columns no longer exist

-- Verify registry:remove-pricing-plan-relationship-fields on pg

BEGIN;

-- Check that the obsolete columns do not exist
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'registry'
          AND table_name = 'pricing_plans'
          AND column_name IN ('target_tenant_id', 'offering_tenant_id')
    ) THEN
        RAISE EXCEPTION 'Columns target_tenant_id or offering_tenant_id still exist in pricing_plans';
    END IF;
END $$;

ROLLBACK;