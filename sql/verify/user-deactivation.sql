-- ABOUTME: Verify every schema holding users can record a deactivation.
-- ABOUTME: Checked across tenants, because a tenant schema is where staff are.

-- Verify registry:user-deactivation on pg

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
        CONTINUE WHEN to_regclass(format('%I.users', s)) IS NULL;

        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
             WHERE table_schema = s AND table_name = 'users'
               AND column_name = 'deactivated_at'
        ) THEN
            RAISE EXCEPTION 'users.deactivated_at missing in schema %', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
