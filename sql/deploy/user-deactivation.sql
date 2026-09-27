-- ABOUTME: A staff member who leaves can be deactivated, which revokes every way in.
-- ABOUTME: Deactivated, not deleted: events.teacher_id and attendance_records.marked_by are history.

-- Deploy registry:user-deactivation to pg
-- requires: pricing-plan-versions

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Offboarding had no answer at all before this, at any level:
--
--   * DELETE is refused -- events.teacher_id is NOT NULL REFERENCES users, and
--     attendance_records.marked_by likewise, so a departed teacher's history is
--     holding their row in place. Which is correct: the register says who marked
--     it, and that must stay true.
--   * there was no state to set, so nothing to UPDATE either
--   * and request_magic_link mints a token for any email it finds, checking
--     nothing, so a departed staff member kept working access indefinitely
--
-- A timestamp rather than a boolean, because an offboarding wants to record WHEN.
-- NULL means active, which is what every existing row is.
ALTER TABLE users ADD COLUMN IF NOT EXISTS deactivated_at timestamp with time zone;

-- The auth path filters on this on every request, for every authenticated user.
CREATE INDEX IF NOT EXISTS idx_users_deactivated_at
    ON users (deactivated_at) WHERE deactivated_at IS NOT NULL;

-- Every tenant keeps its own users table, and a tenant schema is where staff
-- actually are -- copy_user makes a person resident in both.
DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );
        -- Schema existence is not table existence: a half-provisioned tenant
        -- would otherwise abort the whole migration.
        CONTINUE WHEN to_regclass(format('%I.users', s)) IS NULL;

        EXECUTE format(
            'ALTER TABLE %I.users ADD COLUMN IF NOT EXISTS deactivated_at timestamp with time zone',
            s );
        EXECUTE format($f$
            CREATE INDEX IF NOT EXISTS idx_users_deactivated_at
                ON %I.users (deactivated_at) WHERE deactivated_at IS NOT NULL
        $f$, s );
    END LOOP;
END $$;

COMMIT;
