-- ABOUTME: A session can have its waitlist turned off, so a full one is simply full.
-- ABOUTME: Defaults to on, which is what every existing session has been doing.

-- Deploy registry:session-waitlist-toggle to pg
-- requires: tenant-slug-lowercase

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Morgan decides whether a full session collects a queue. Some do not want
-- one: a session that will not run again, or a programme where waiting is
-- misleading rather than useful.
--
-- Default TRUE because that is what every session has effectively been doing
-- since the waitlist existed, and a migration should not quietly change how
-- anybody's programme behaves.
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS waitlist_enabled boolean NOT NULL DEFAULT true;

-- Every tenant keeps its own copy of this table. A column added only to
-- registry is a column the customer schemas do not have, and every read of it
-- there fails -- which is the half that holds the actual programmes.
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
        CONTINUE WHEN to_regclass(format('%I.sessions', s)) IS NULL;

        EXECUTE format(
            'ALTER TABLE %I.sessions ADD COLUMN IF NOT EXISTS waitlist_enabled boolean NOT NULL DEFAULT true',
            s
        );
    END LOOP;
END $$;

COMMIT;
