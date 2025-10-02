-- ABOUTME: Verify migration created pricing relationships for default platform pricing plans
-- ABOUTME: Ensures all tenant-scoped plans have corresponding active pricing relationships

-- Verify registry:create-default-pricing-relationships on pg

BEGIN;

-- Verify platform tenant exists
SELECT 1/COUNT(*) FROM registry.tenants
WHERE id = '00000000-0000-0000-0000-000000000000'::UUID;

-- Verify platform admin user exists
SELECT 1/COUNT(*) FROM registry.users u
JOIN registry.tenant_users tu ON tu.user_id = u.id
WHERE tu.tenant_id = '00000000-0000-0000-0000-000000000000'::UUID
AND tu.is_primary = true;

-- Verify all tenant-scoped pricing plans have active pricing relationships
SELECT 1/COUNT(*) FROM registry.pricing_plans p
WHERE p.plan_scope = 'tenant'
AND EXISTS (
    SELECT 1 FROM registry.pricing_relationships pr
    WHERE pr.provider_id = '00000000-0000-0000-0000-000000000000'::UUID
    AND pr.pricing_plan_id = p.id
    AND pr.status = 'active'
);

ROLLBACK;