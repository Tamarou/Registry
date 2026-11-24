-- ABOUTME: Verify the bootstrap's resources, published offer versions and registry's entitlements exist.
-- ABOUTME: Without them signup offers nothing and the platform holds none of its own rights.

-- Verify registry:bootstrap-platform-offers on pg

BEGIN;

DO $$
BEGIN
    IF (SELECT count(*) FROM registry.resources
         WHERE id::text LIKE '00000000-0000-0000-0001-%') <> 7
    OR (SELECT count(*) FROM registry.offer_versions
         WHERE id::text LIKE '00000000-0000-0000-0003-%' AND published_at IS NOT NULL) <> 8
    OR (SELECT count(*) FROM registry.entitlements
         WHERE id::text LIKE '00000000-0000-0000-0004-%'
           AND holder_tenant_id = '00000000-0000-0000-0000-000000000000') <> 7
    THEN
        RAISE EXCEPTION 'the bootstrap''s Solo v1, self offers or registry''s entitlements are missing';
    END IF;
END $$;

ROLLBACK;
