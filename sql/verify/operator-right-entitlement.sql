-- ABOUTME: Verify the platform holds the operator right as a registry entitlement and the interim table is gone.
-- ABOUTME: Without the entitlement nobody is served acting as a tenant, the job queue or the revenue view.

-- Verify registry:operator-right-entitlement on pg

BEGIN;

DO $$
BEGIN
    IF to_regclass('registry.tenant_resources') IS NOT NULL THEN
        RAISE EXCEPTION 'the interim registry.tenant_resources table still exists';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM registry.entitlements e
                     JOIN registry.offer_versions v ON v.id = e.offer_version_id
                     JOIN registry.resources r      ON r.id = v.resource_id
                    WHERE r.name = 'operator'
                      AND e.holder_tenant_id = '00000000-0000-0000-0000-000000000000') THEN
        RAISE EXCEPTION 'the platform tenant does not hold the operator right';
    END IF;
END $$;

ROLLBACK;
