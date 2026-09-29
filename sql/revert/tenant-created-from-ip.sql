-- ABOUTME: Drop the provisioning-address column and its index.
-- ABOUTME: Provisioning loses its durable rate limit; the addresses recorded so far are discarded.

-- Revert registry:tenant-created-from-ip from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

DROP INDEX IF EXISTS idx_tenants_created_from_ip_created_at;
ALTER TABLE tenants DROP COLUMN IF EXISTS created_from_ip;

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );
        CONTINUE WHEN to_regclass(format('%I.tenants', s)) IS NULL;
        EXECUTE format(
            'ALTER TABLE %I.tenants DROP COLUMN IF EXISTS created_from_ip', s );
    END LOOP;
END $$;

COMMIT;
