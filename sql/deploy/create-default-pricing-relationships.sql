-- ABOUTME: Migration to create missing pricing relationships for default platform pricing plans
-- ABOUTME: Ensures default platform plans are discoverable through PricingPlanSelection workflow step

-- Deploy registry:create-default-pricing-relationships to pg
-- requires: remove-pricing-plan-relationship-fields

BEGIN;

-- Create pricing relationships for default platform pricing plans
-- First, ensure platform tenant has a primary admin user
DO $$
DECLARE
    platform_id UUID := '00000000-0000-0000-0000-000000000000'::UUID;
    platform_admin_id UUID;
    plan_record RECORD;
BEGIN
    -- Check if platform tenant has a primary admin user
    SELECT u.id INTO platform_admin_id
    FROM registry.users u
    JOIN registry.tenant_users tu ON tu.user_id = u.id
    WHERE tu.tenant_id = platform_id
    AND tu.is_primary = true
    LIMIT 1;

    -- If no primary admin exists, create one
    IF platform_admin_id IS NULL THEN
        platform_admin_id := gen_random_uuid();

        INSERT INTO registry.users (id, username, passhash, user_type)
        VALUES (
            platform_admin_id,
            'platform_admin',
            '$2b$12$DummyHashForSystemUser',
            'admin'
        );

        INSERT INTO registry.user_profiles (user_id, email, name)
        VALUES (
            platform_admin_id,
            'admin@registry.platform',
            'Platform Admin'
        );

        INSERT INTO registry.tenant_users (tenant_id, user_id, is_primary)
        VALUES (
            platform_id,
            platform_admin_id,
            true
        );
    END IF;

    -- Create pricing relationships for all platform tenant-scoped plans that don't have relationships
    FOR plan_record IN
        SELECT p.id, p.plan_name
        FROM registry.pricing_plans p
        WHERE p.plan_scope = 'tenant'
        AND NOT EXISTS (
            SELECT 1 FROM registry.pricing_relationships pr
            WHERE pr.provider_id = platform_id
            AND pr.pricing_plan_id = p.id
        )
    LOOP
        INSERT INTO registry.pricing_relationships (
            provider_id,
            consumer_id,
            pricing_plan_id,
            status,
            metadata
        ) VALUES (
            platform_id,
            platform_admin_id,
            plan_record.id,
            'active',
            jsonb_build_object(
                'plan_type', 'tenant_subscription',
                'created_by_migration', 'create-default-pricing-relationships',
                'plan_name', plan_record.plan_name
            )
        );
    END LOOP;
END $$;

COMMIT;