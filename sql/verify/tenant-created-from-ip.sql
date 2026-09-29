-- ABOUTME: Verify every schema holding a tenants table records the provisioning address.
-- ABOUTME: Checked across tenants, because clone_schema promises structurally identical copies.

-- Verify registry:tenant-created-from-ip on pg

BEGIN;

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.tenants', s)) IS NULL;

        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
             WHERE table_schema = s AND table_name = 'tenants'
               AND column_name = 'created_from_ip'
        ) THEN
            RAISE EXCEPTION 'tenants.created_from_ip missing in schema %', s;
        END IF;
    END LOOP;
END $$;

-- The index the rate-limit query depends on. Without it the count is a seq scan
-- over every tenant on every signup.
DO $$
BEGIN
    IF to_regclass('registry.idx_tenants_created_from_ip_created_at') IS NULL THEN
        RAISE EXCEPTION 'idx_tenants_created_from_ip_created_at missing';
    END IF;
END $$;

ROLLBACK;
