-- ABOUTME: Verify the platform is one tenant row: slug registry, the all-zeros id.
-- ABOUTME: And that the retired registry-platform slug names nothing.

-- Verify registry:collapse-platform-tenant on pg

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM registry.tenants
         WHERE slug = 'registry'
           AND id   = '00000000-0000-0000-0000-000000000000'
    ) THEN
        RAISE EXCEPTION 'the registry tenant is not the all-zeros platform row';
    END IF;

    IF EXISTS (SELECT 1 FROM registry.tenants WHERE slug = 'registry-platform') THEN
        RAISE EXCEPTION 'a tenant still carries the retired registry-platform slug';
    END IF;
END $$;

ROLLBACK;
