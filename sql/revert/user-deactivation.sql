-- ABOUTME: Remove user deactivation.
-- ABOUTME: Every deactivated account silently regains access, including departed staff.

-- Revert registry:user-deactivation from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

DROP INDEX IF EXISTS idx_users_deactivated_at;
ALTER TABLE users DROP COLUMN IF EXISTS deactivated_at;

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );
        CONTINUE WHEN to_regclass(format('%I.users', s)) IS NULL;
        EXECUTE format('DROP INDEX IF EXISTS %I.idx_users_deactivated_at', s);
        EXECUTE format('ALTER TABLE %I.users DROP COLUMN IF EXISTS deactivated_at', s);
    END LOOP;
END $$;

COMMIT;
