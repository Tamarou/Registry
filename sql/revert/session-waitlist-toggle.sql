-- ABOUTME: Remove the per-session waitlist toggle.
-- ABOUTME: Any session that had its waitlist turned off silently regains one.

-- Revert registry:session-waitlist-toggle from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

ALTER TABLE sessions DROP COLUMN IF EXISTS waitlist_enabled;

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );
        CONTINUE WHEN to_regclass(format('%I.sessions', s)) IS NULL;
        EXECUTE format( 'ALTER TABLE %I.sessions DROP COLUMN IF EXISTS waitlist_enabled', s );
    END LOOP;
END $$;

COMMIT;
